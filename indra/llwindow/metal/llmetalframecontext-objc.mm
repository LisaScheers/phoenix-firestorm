/**
 * @file llmetalframecontext-objc.mm
 * @brief Objective-C++ implementation of Metal frame contexts.
 *
 * $LicenseInfo:firstyear=2026&license=viewerlgpl$
 * Phoenix Firestorm Viewer Source Code
 * Copyright (C) 2026, Firestorm Viewer Project
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation;
 * version 2.1 of the License only.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 * $/LicenseInfo$
 */

#import <Metal/Metal.h>

#include "llmetalframecontext.h"
#include "llmetaltransientarena.h"

#include <array>
#include <cstdint>
#include <limits>
#include <mutex>
#include <utility>

namespace firestorm::metal
{

namespace
{

bool conformsToMetalProtocol(void* handle, Protocol* protocol)
{
    id object = (__bridge id)handle;
    return object != nil && [object conformsToProtocol:protocol];
}

enum class ContextState
{
    available,
    recording,
    submitted,
};

struct ContextStorage
{
    ContextStorage(id<MTLDevice> device, std::size_t capacity) :
        buffer(device == nil || capacity == 0
                   ? nil
                   : [device newBufferWithLength:capacity options:MTLResourceStorageModeShared]),
        arena(capacity),
        retired([[NSMutableArray alloc] init])
    {
    }

    __strong id<MTLBuffer>                     buffer;
    TransientArena                             arena;
    __strong NSMutableArray<id<MTLResource>>* retired;
    MetalFrameContext::CompletionAction          completion_action;
    std::uint64_t                                submission_serial = 0;
    ContextState                               state      = ContextState::available;
    std::uint64_t                              generation = 0;
};

} // namespace

struct MetalFrameContext::Impl final : std::enable_shared_from_this<MetalFrameContext::Impl>
{
    Impl(id<MTLDevice> device, std::size_t capacity) :
        mDevice(device),
        mContexts{ ContextStorage(device, capacity),
                   ContextStorage(device, capacity),
                   ContextStorage(device, capacity) },
        mCapacity(capacity)
    {
        mValid = mDevice != nil && mCapacity != 0;
        for (const ContextStorage& context : mContexts)
        {
            mValid = mValid && context.buffer != nil;
        }
    }

    bool valid() const noexcept
    {
        return mValid;
    }

    std::optional<MetalFrameLease> tryBegin()
    {
        std::lock_guard<std::mutex> lock(mMutex);
        if (!mValid)
        {
            return std::nullopt;
        }

        const std::optional<FrameToken> token = mSlots.tryBegin();
        if (!token)
        {
            return std::nullopt;
        }

        ContextStorage& context = mContexts[token->slot];
        if (context.state != ContextState::available || context.retired.count != 0 || context.arena.used() != 0)
        {
            (void)mSlots.cancel(*token);
            return std::nullopt;
        }

        context.state      = ContextState::recording;
        context.generation = token->generation;
        return MetalFrameLease{ *token, (__bridge void*)context.buffer, mCapacity };
    }

    std::optional<MetalFrameAllocation> allocate(FrameToken token,
                                                 std::size_t size,
                                                 std::size_t alignment)
    {
        std::lock_guard<std::mutex> lock(mMutex);
        ContextStorage* const context = matching(token, ContextState::recording);
        if (context == nullptr)
        {
            return std::nullopt;
        }

        const std::optional<TransientRange> range = context->arena.allocate(size, alignment);
        if (!range)
        {
            return std::nullopt;
        }

        auto* const base = static_cast<std::byte*>(context->buffer.contents);
        return MetalFrameAllocation{ range->offset, range->size, base + range->offset };
    }

    bool retire(FrameToken token, id<MTLResource> resource)
    {
        std::lock_guard<std::mutex> lock(mMutex);
        ContextStorage* const context = matching(token, ContextState::recording);
        if (context == nullptr || resource == nil)
        {
            return false;
        }

        [context->retired addObject:resource];
        return true;
    }

    std::optional<std::uint64_t> submit(FrameToken token,
                                        id<MTLCommandBuffer> command_buffer,
                                        CompletionAction completion_action)
    {
        std::lock_guard<std::mutex> lock(mMutex);
        ContextStorage* const context = matching(token, ContextState::recording);
        const MTLCommandBufferStatus command_status = command_buffer == nil
                                                          ? MTLCommandBufferStatusError
                                                          : command_buffer.status;
        if (context == nullptr || command_buffer == nil ||
            (command_status != MTLCommandBufferStatusNotEnqueued &&
             command_status != MTLCommandBufferStatusEnqueued) ||
            mSubmissionSerial == std::numeric_limits<std::uint64_t>::max())
        {
            return std::nullopt;
        }

        const std::uint64_t submission_serial = mSubmissionSerial + 1;
        if (!mSlots.submit(token))
        {
            return std::nullopt;
        }

        mSubmissionSerial          = submission_serial;
        context->state             = ContextState::submitted;
        context->submission_serial = submission_serial;
        context->completion_action = std::move(completion_action);
        const std::shared_ptr<Impl> keep_alive = shared_from_this();
        [command_buffer addCompletedHandler:^(id<MTLCommandBuffer> completed_buffer) {
            @autoreleasepool
            {
                keep_alive->complete(token, completed_buffer.status == MTLCommandBufferStatusCompleted);
            }
        }];
        return submission_serial;
    }

    bool cancel(FrameToken token)
    {
        std::lock_guard<std::mutex> lock(mMutex);
        ContextStorage* const context = matching(token, ContextState::recording);
        if (context == nullptr)
        {
            return false;
        }

        // Publish availability only after generation-owned state is gone.
        [context->retired removeAllObjects];
        context->arena.reset();
        context->completion_action = {};
        context->submission_serial = 0;
        if (!mSlots.cancel(token))
        {
            return false;
        }

        context->state = ContextState::available;
        return true;
    }

    void complete(FrameToken token, bool succeeded)
    {
        CompletionAction completion_action;
        std::uint64_t     submission_serial = 0;
        {
            std::lock_guard<std::mutex> lock(mMutex);
            ContextStorage* const context = matching(token, ContextState::submitted);
            if (context == nullptr)
            {
                return;
            }

            // Retire the exact generation and reset its CPU allocator before a
            // producer can observe this slot as available again.
            [context->retired removeAllObjects];
            context->arena.reset();
            submission_serial          = context->submission_serial;
            context->submission_serial = 0;
            completion_action          = std::move(context->completion_action);
            context->completion_action = {};
            if (!mSlots.complete(token))
            {
                return;
            }

            context->state = ContextState::available;
        }

        if (succeeded && completion_action)
        {
            try
            {
                completion_action(submission_serial);
            }
            catch (...)
            {
                // The slot and its retired resources are already finalized.
                // Never unwind a client callback through Metal's completion block.
            }
        }
    }

private:
    ContextStorage* matching(FrameToken token, ContextState expected)
    {
        if (token.slot >= mContexts.size())
        {
            return nullptr;
        }

        ContextStorage& context = mContexts[token.slot];
        if (context.generation != token.generation || context.state != expected)
        {
            return nullptr;
        }

        return &context;
    }

    __strong id<MTLDevice>                mDevice;
    std::array<ContextStorage, kContextCount> mContexts;
    std::size_t                           mCapacity = 0;
    bool                                  mValid    = false;
    std::uint64_t                         mSubmissionSerial = 0;
    FrameSlots                            mSlots;
    std::mutex                            mMutex;
};

MetalFrameContext::MetalFrameContext(MetalDeviceHandle device, std::size_t bytes_per_context) :
    mImpl(std::make_shared<Impl>(conformsToMetalProtocol(device, @protocol(MTLDevice))
                                    ? (__bridge id<MTLDevice>)device
                                    : nil,
                                bytes_per_context))
{
}

MetalFrameContext::~MetalFrameContext() = default;

bool MetalFrameContext::valid() const noexcept
{
    return mImpl != nullptr && mImpl->valid();
}

std::optional<MetalFrameLease> MetalFrameContext::tryBegin()
{
    return mImpl == nullptr ? std::nullopt : mImpl->tryBegin();
}

std::optional<MetalFrameAllocation> MetalFrameContext::allocate(FrameToken token,
                                                                std::size_t size,
                                                                std::size_t alignment)
{
    return mImpl == nullptr ? std::nullopt : mImpl->allocate(token, size, alignment);
}

bool MetalFrameContext::retire(FrameToken token, MetalResourceHandle resource)
{
    return mImpl != nullptr && conformsToMetalProtocol(resource, @protocol(MTLResource)) &&
           mImpl->retire(token, (__bridge id<MTLResource>)resource);
}

std::optional<std::uint64_t> MetalFrameContext::submit(FrameToken token,
                                                       MetalCommandBufferHandle command_buffer,
                                                       CompletionAction completion_action)
{
    return mImpl == nullptr || !conformsToMetalProtocol(command_buffer, @protocol(MTLCommandBuffer))
               ? std::nullopt
               : mImpl->submit(token,
                               (__bridge id<MTLCommandBuffer>)command_buffer,
                               std::move(completion_action));
}

bool MetalFrameContext::cancel(FrameToken token)
{
    return mImpl != nullptr && mImpl->cancel(token);
}

} // namespace firestorm::metal
