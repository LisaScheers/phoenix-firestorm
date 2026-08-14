/**
 * @file llmetaltransfer-objc.mm
 * @brief Objective-C++ implementation of bounded Metal resource transfers.
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

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "llmetaltransfer.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <utility>

namespace firestorm::metal
{
namespace
{

constexpr std::size_t kBufferCopyAlignment  = 4;
constexpr std::size_t kTextureCopyAlignment = 256;

bool conformsToMetalProtocol(void* handle, Protocol* protocol)
{
    id object = (__bridge id)handle;
    return object != nil && [object conformsToProtocol:protocol];
}

bool isPreCommit(MTLCommandBufferStatus status) noexcept
{
    return status == MTLCommandBufferStatusNotEnqueued ||
           status == MTLCommandBufferStatusEnqueued;
}

bool checkedAdd(std::size_t lhs, std::size_t rhs, std::size_t& result) noexcept
{
    if (rhs > std::numeric_limits<std::size_t>::max() - lhs)
    {
        return false;
    }
    result = lhs + rhs;
    return true;
}

bool checkedMultiply(std::size_t lhs, std::size_t rhs, std::size_t& result) noexcept
{
    if (lhs != 0 && rhs > std::numeric_limits<std::size_t>::max() / lhs)
    {
        return false;
    }
    result = lhs * rhs;
    return true;
}

std::uint32_t maximumMipLevels(std::uint32_t width, std::uint32_t height) noexcept
{
    std::uint32_t dimension = std::max(width, height);
    std::uint32_t levels    = 0;
    while (dimension != 0)
    {
        ++levels;
        dimension >>= 1U;
    }
    return levels;
}

std::uint32_t mipExtent(std::uint32_t base, std::uint32_t level) noexcept
{
    while (level != 0 && base > 1)
    {
        base >>= 1U;
        --level;
    }
    return std::max<std::uint32_t>(base, 1);
}

constexpr std::uint8_t kKnownTextureUsage =
    static_cast<std::uint8_t>(MetalTextureUsage::shader_read) |
    static_cast<std::uint8_t>(MetalTextureUsage::shader_write) |
    static_cast<std::uint8_t>(MetalTextureUsage::render_target);

bool validTextureDescriptor(const MetalTexture2DDescriptor& descriptor) noexcept
{
    const std::uint8_t usage = static_cast<std::uint8_t>(descriptor.usage);
    return formatInfo(descriptor.format).has_value() && descriptor.width != 0 &&
           descriptor.height != 0 && descriptor.mipLevels != 0 &&
           descriptor.mipLevels <= maximumMipLevels(descriptor.width, descriptor.height) &&
           usage != 0 && (usage & static_cast<std::uint8_t>(~kKnownTextureUsage)) == 0 &&
           !(descriptor.format == PixelFormat::depth32_float &&
             hasUsage(descriptor.usage, MetalTextureUsage::shader_write));
}

bool validTextureSource(const MetalTexture2DDescriptor& descriptor,
                        MetalTextureUpload2D             source,
                        SubresourceLayout&               tight_layout,
                        SubresourceLayout&               staging_layout) noexcept
{
    if (!validTextureDescriptor(descriptor) || source.bytes.data == nullptr ||
        source.bytesPerRow == 0)
    {
        return false;
    }

    const auto tight = makeSubresourceLayout(descriptor.format,
                                             descriptor.width,
                                             descriptor.height,
                                             1);
    const auto staging = makeSubresourceLayout(descriptor.format,
                                               descriptor.width,
                                               descriptor.height,
                                               kTextureCopyAlignment);
    if (!tight || !staging || source.bytesPerRow < tight->bytesPerRow)
    {
        return false;
    }

    std::size_t preceding_rows = 0;
    std::size_t required_bytes = 0;
    if (!checkedMultiply(source.bytesPerRow,
                         static_cast<std::size_t>(descriptor.height - 1U),
                         preceding_rows) ||
        !checkedAdd(preceding_rows, tight->bytesPerRow, required_bytes) ||
        source.bytes.size < required_bytes)
    {
        return false;
    }

    tight_layout   = *tight;
    staging_layout = *staging;
    return true;
}

struct SharedReadback
{
    explicit SharedReadback(id<MTLBuffer> native_buffer) : buffer(native_buffer) {}
    __strong id<MTLBuffer> buffer;
};

enum class BatchState
{
    active,
    finished,
    canceled,
};

} // namespace

struct MetalTransferBatch::Impl
{
    Impl(MetalDeviceHandle        device_handle,
         MetalFrameContext&       frames,
         MetalFrameLease          lease,
         MetalCommandBufferHandle command_buffer_handle,
         std::size_t              readback_budget_bytes) :
        mFrames(&frames),
        mLease(lease),
        mReadbackBudget(readback_budget_bytes)
    {
        mDevice = conformsToMetalProtocol(device_handle, @protocol(MTLDevice))
                      ? (__bridge id<MTLDevice>)device_handle
                      : nil;
        mStagingBuffer = conformsToMetalProtocol(lease.buffer, @protocol(MTLBuffer))
                             ? (__bridge id<MTLBuffer>)lease.buffer
                             : nil;
        mCommandBuffer = conformsToMetalProtocol(command_buffer_handle,
                                                 @protocol(MTLCommandBuffer))
                             ? (__bridge id<MTLCommandBuffer>)command_buffer_handle
                             : nil;

        const bool owns_lease = frames.ownsRecordingLease(lease);
        mOwnsLease = owns_lease;
        mValid = owns_lease &&
                 mDevice != nil && mStagingBuffer != nil && mCommandBuffer != nil &&
                 lease.capacity != 0 && lease.capacity <= mStagingBuffer.length &&
                 mStagingBuffer.storageMode == MTLStorageModeShared &&
                 mStagingBuffer.device == mDevice && mCommandBuffer.device == mDevice &&
                 isPreCommit(mCommandBuffer.status);
    }

    ~Impl()
    {
        cancel();
    }

    bool valid() const noexcept
    {
        return mValid && mState == BatchState::active && mCommandBuffer != nil &&
               isPreCommit(mCommandBuffer.status);
    }

    MetalDeviceHandle deviceHandle() const noexcept
    {
        return mDevice == nil ? nullptr : (__bridge void*)mDevice;
    }

    MetalTransferStatus uploadBuffer(MetalByteView       source,
                                     MetalPrivateBuffer buffer,
                                     PublishBuffer      publish)
    {
        if (!valid())
        {
            return MetalTransferStatus::invalid_state;
        }
        if (source.data == nullptr || source.size == 0 || !buffer.valid() || !publish ||
            !resourceBelongsToDevice(buffer.nativeHandle(), @protocol(MTLBuffer)))
        {
            return MetalTransferStatus::invalid_argument;
        }

        const auto staging = mFrames->allocate(mLease.token,
                                               source.size,
                                               kBufferCopyAlignment);
        if (!staging)
        {
            return MetalTransferStatus::staging_full;
        }
        std::memcpy(staging->bytes, source.data, source.size);

        id<MTLBlitCommandEncoder> encoder = ensureEncoder();
        if (encoder == nil)
        {
            return MetalTransferStatus::encoder_unavailable;
        }
        if (!mFrames->retire(mLease.token, buffer.nativeHandle()))
        {
            return MetalTransferStatus::retirement_failed;
        }

        id<MTLBuffer> destination = (__bridge id<MTLBuffer>)buffer.nativeHandle();
        [encoder copyFromBuffer:mStagingBuffer
                   sourceOffset:staging->offset
                       toBuffer:destination
              destinationOffset:0
                           size:source.size];

        mActions.emplace_back(
            [buffer = std::move(buffer), publish = std::move(publish)](
                std::uint64_t submission_serial) mutable {
                try
                {
                    publish(submission_serial, std::move(buffer));
                }
                catch (...)
                {
                    // One consumer must not suppress later publications.
                }
            });
        return MetalTransferStatus::encoded;
    }

    MetalTransferStatus uploadTexture(const MetalTexture2DDescriptor& descriptor,
                                      MetalTextureUpload2D             source,
                                      MetalPrivateTexture2D            texture,
                                      PublishTexture                   publish)
    {
        if (!valid())
        {
            return MetalTransferStatus::invalid_state;
        }

        SubresourceLayout tight_layout;
        SubresourceLayout staging_layout;
        if (!publish || !texture.valid() ||
            !resourceBelongsToDevice(texture.nativeHandle(), @protocol(MTLTexture)) ||
            !validTextureSource(descriptor, source, tight_layout, staging_layout))
        {
            return MetalTransferStatus::invalid_argument;
        }

        const auto staging = mFrames->allocate(mLease.token,
                                               staging_layout.bytesPerImage,
                                               kTextureCopyAlignment);
        if (!staging)
        {
            return MetalTransferStatus::staging_full;
        }

        std::memset(staging->bytes, 0, staging_layout.bytesPerImage);
        auto* destination_bytes = static_cast<std::byte*>(staging->bytes);
        for (std::uint32_t row = 0; row < descriptor.height; ++row)
        {
            const std::size_t destination_offset =
                static_cast<std::size_t>(row) * staging_layout.bytesPerRow;
            const std::size_t source_offset =
                static_cast<std::size_t>(row) * source.bytesPerRow;
            std::memcpy(destination_bytes + destination_offset,
                        source.bytes.data + source_offset,
                        tight_layout.bytesPerRow);
        }

        id<MTLBlitCommandEncoder> encoder = ensureEncoder();
        if (encoder == nil)
        {
            return MetalTransferStatus::encoder_unavailable;
        }
        if (!mFrames->retire(mLease.token, texture.nativeHandle()))
        {
            return MetalTransferStatus::retirement_failed;
        }

        id<MTLTexture> destination = (__bridge id<MTLTexture>)texture.nativeHandle();
        [encoder copyFromBuffer:mStagingBuffer
                   sourceOffset:staging->offset
              sourceBytesPerRow:staging_layout.bytesPerRow
            sourceBytesPerImage:staging_layout.bytesPerImage
                     sourceSize:MTLSizeMake(descriptor.width, descriptor.height, 1)
                      toTexture:destination
               destinationSlice:0
               destinationLevel:0
              destinationOrigin:MTLOriginMake(0, 0, 0)];

        mActions.emplace_back(
            [texture = std::move(texture), publish = std::move(publish)](
                std::uint64_t submission_serial) mutable {
                try
                {
                    publish(submission_serial, std::move(texture));
                }
                catch (...)
                {
                    // One consumer must not suppress later publications.
                }
            });
        return MetalTransferStatus::encoded;
    }

    MetalTransferStatus readbackBuffer(const MetalPrivateBuffer& source,
                                       std::size_t               offset,
                                       std::size_t               size,
                                       PublishBufferReadback     publish)
    {
        if (!valid())
        {
            return MetalTransferStatus::invalid_state;
        }
        if (!source.valid() || !publish || size == 0 ||
            offset % kBufferCopyAlignment != 0 || offset > source.size() ||
            size > source.size() - offset ||
            !resourceBelongsToDevice(source.nativeHandle(), @protocol(MTLBuffer)))
        {
            return MetalTransferStatus::invalid_argument;
        }
        if (!fitsReadbackBudget(size))
        {
            return MetalTransferStatus::readback_budget_exceeded;
        }

        id<MTLBuffer> readback = [mDevice newBufferWithLength:size
                                                     options:MTLResourceStorageModeShared];
        if (readback == nil)
        {
            return MetalTransferStatus::resource_allocation_failed;
        }
        readback.label = @"Firestorm private buffer readback";

        id<MTLBlitCommandEncoder> encoder = ensureEncoder();
        if (encoder == nil)
        {
            return MetalTransferStatus::encoder_unavailable;
        }
        if (!mFrames->retire(mLease.token, source.nativeHandle()))
        {
            return MetalTransferStatus::retirement_failed;
        }

        id<MTLBuffer> source_buffer = (__bridge id<MTLBuffer>)source.nativeHandle();
        [encoder copyFromBuffer:source_buffer
                   sourceOffset:offset
                       toBuffer:readback
              destinationOffset:0
                           size:size];
        mReadbackUsed += size;

        auto storage = std::make_shared<SharedReadback>(readback);
        mActions.emplace_back(
            [storage = std::move(storage), offset, size, publish = std::move(publish)](
                std::uint64_t submission_serial) mutable {
                try
                {
                    MetalBufferReadback result;
                    result.sourceOffset = offset;
                    result.bytes.resize(size);
                    std::memcpy(result.bytes.data(), storage->buffer.contents, size);
                    publish(submission_serial, std::move(result));
                }
                catch (...)
                {
                    // Failed CPU publication cannot invalidate GPU completion.
                }
            });
        return MetalTransferStatus::encoded;
    }

    MetalTransferStatus readbackTexture(const MetalPrivateTexture2D& source,
                                        MetalTextureRegion            region,
                                        PublishTextureReadback        publish)
    {
        if (!valid())
        {
            return MetalTransferStatus::invalid_state;
        }
        if (!source.valid() || !publish ||
            !resourceBelongsToDevice(source.nativeHandle(), @protocol(MTLTexture)) ||
            region.slice != 0 || region.mipLevel >= source.mipLevels() ||
            region.width == 0 || region.height == 0)
        {
            return MetalTransferStatus::invalid_argument;
        }

        const std::uint32_t mip_width  = mipExtent(source.width(), region.mipLevel);
        const std::uint32_t mip_height = mipExtent(source.height(), region.mipLevel);
        if (region.x >= mip_width || region.y >= mip_height ||
            region.width > mip_width - region.x ||
            region.height > mip_height - region.y)
        {
            return MetalTransferStatus::invalid_argument;
        }

        const auto layout = makeSubresourceLayout(source.format(),
                                                  region.width,
                                                  region.height,
                                                  kTextureCopyAlignment);
        if (!layout)
        {
            return MetalTransferStatus::invalid_argument;
        }
        if (!fitsReadbackBudget(layout->bytesPerImage))
        {
            return MetalTransferStatus::readback_budget_exceeded;
        }

        id<MTLBuffer> readback = [mDevice newBufferWithLength:layout->bytesPerImage
                                                     options:MTLResourceStorageModeShared];
        if (readback == nil)
        {
            return MetalTransferStatus::resource_allocation_failed;
        }
        readback.label = @"Firestorm private texture readback";

        id<MTLBlitCommandEncoder> encoder = ensureEncoder();
        if (encoder == nil)
        {
            return MetalTransferStatus::encoder_unavailable;
        }
        if (!mFrames->retire(mLease.token, source.nativeHandle()))
        {
            return MetalTransferStatus::retirement_failed;
        }

        id<MTLTexture> source_texture = (__bridge id<MTLTexture>)source.nativeHandle();
        [encoder copyFromTexture:source_texture
                     sourceSlice:region.slice
                     sourceLevel:region.mipLevel
                    sourceOrigin:MTLOriginMake(region.x, region.y, 0)
                      sourceSize:MTLSizeMake(region.width, region.height, 1)
                        toBuffer:readback
               destinationOffset:0
          destinationBytesPerRow:layout->bytesPerRow
        destinationBytesPerImage:layout->bytesPerImage];
        mReadbackUsed += layout->bytesPerImage;

        auto storage = std::make_shared<SharedReadback>(readback);
        const PixelFormat format = source.format();
        mActions.emplace_back(
            [storage = std::move(storage), format, region, layout = *layout,
             publish = std::move(publish)](std::uint64_t submission_serial) mutable {
                try
                {
                    MetalTextureReadback result;
                    result.format        = format;
                    result.region        = region;
                    result.bytesPerRow   = layout.bytesPerRow;
                    result.bytesPerImage = layout.bytesPerImage;
                    result.bytes.resize(layout.bytesPerImage);
                    std::memcpy(result.bytes.data(),
                                storage->buffer.contents,
                                layout.bytesPerImage);
                    publish(submission_serial, std::move(result));
                }
                catch (...)
                {
                    // Failed CPU publication cannot invalidate GPU completion.
                }
            });
        return MetalTransferStatus::encoded;
    }

    std::optional<MetalFrameContext::CompletionAction> finish()
    {
        if (!valid())
        {
            return std::nullopt;
        }

        // Copy first so allocation failure leaves the batch, lease, encoder,
        // and original publications intact and therefore safely cancellable.
        MetalFrameContext::CompletionAction completion_action(
            [actions = mActions](std::uint64_t submission_serial) mutable {
                for (auto& action : actions)
                {
                    try
                    {
                        action(submission_serial);
                    }
                    catch (...)
                    {
                        // Each pending publication is independent.
                    }
                }
            });
        std::optional<MetalFrameContext::CompletionAction> result(
            std::in_place,
            std::move(completion_action));

        endEncoder();
        mState     = BatchState::finished;
        mOwnsLease = false;
        mActions.clear();
        return result;
    }

    void cancel() noexcept
    {
        if (mState != BatchState::active)
        {
            return;
        }

        endEncoder();
        mActions.clear();
        if (mOwnsLease && mFrames != nullptr)
        {
            (void)mFrames->cancel(mLease.token);
        }
        mOwnsLease = false;
        mState     = BatchState::canceled;
    }

private:
    bool resourceBelongsToDevice(void* handle, Protocol* protocol) const
    {
        if (!conformsToMetalProtocol(handle, protocol))
        {
            return false;
        }
        id<MTLResource> resource = (__bridge id<MTLResource>)handle;
        return resource.device == mDevice;
    }

    bool fitsReadbackBudget(std::size_t bytes) const noexcept
    {
        return bytes <= mReadbackBudget && mReadbackUsed <= mReadbackBudget - bytes;
    }

    id<MTLBlitCommandEncoder> ensureEncoder()
    {
        if (mEncoder != nil)
        {
            return mEncoder;
        }
        if (!valid())
        {
            return nil;
        }

        mEncoder = [mCommandBuffer blitCommandEncoder];
        if (mEncoder != nil)
        {
            mEncoder.label = @"Firestorm bounded resource transfers";
        }
        return mEncoder;
    }

    void endEncoder() noexcept
    {
        if (mEncoder != nil)
        {
            [mEncoder endEncoding];
            mEncoder = nil;
        }
    }

    __strong id<MTLDevice>             mDevice;
    __strong id<MTLBuffer>             mStagingBuffer;
    __strong id<MTLCommandBuffer>      mCommandBuffer;
    __strong id<MTLBlitCommandEncoder> mEncoder;
    MetalFrameContext*                  mFrames = nullptr;
    MetalFrameLease                     mLease;
    std::size_t                         mReadbackBudget = 0;
    std::size_t                         mReadbackUsed   = 0;
    std::vector<std::function<void(std::uint64_t)>> mActions;
    bool                                mValid     = false;
    bool                                mOwnsLease = false;
    BatchState                          mState     = BatchState::active;
};

MetalTransferBatch::MetalTransferBatch(MetalDeviceHandle        device,
                                       MetalFrameContext&       frames,
                                       MetalFrameLease          lease,
                                       MetalCommandBufferHandle command_buffer,
                                       std::size_t              readback_budget_bytes) :
    mImpl(std::make_unique<Impl>(device,
                                 frames,
                                 lease,
                                 command_buffer,
                                 readback_budget_bytes))
{
}

MetalTransferBatch::~MetalTransferBatch() = default;

bool MetalTransferBatch::valid() const noexcept
{
    return mImpl != nullptr && mImpl->valid();
}

MetalTransferStatus MetalTransferBatch::uploadPrivateBuffer(MetalByteView source,
                                                            std::string label,
                                                            PublishBuffer publish)
{
    if (!valid())
    {
        return MetalTransferStatus::invalid_state;
    }
    if (source.data == nullptr || source.size == 0 || !publish)
    {
        return MetalTransferStatus::invalid_argument;
    }

    auto buffer = MetalPrivateBuffer::create(mImpl->deviceHandle(), source.size, label);
    if (!buffer)
    {
        return MetalTransferStatus::resource_allocation_failed;
    }
    return mImpl->uploadBuffer(source, std::move(*buffer), std::move(publish));
}

MetalTransferStatus MetalTransferBatch::uploadPrivateTexture2D(
    const MetalTexture2DDescriptor& descriptor,
    MetalTextureUpload2D             source,
    PublishTexture                   publish)
{
    if (!valid())
    {
        return MetalTransferStatus::invalid_state;
    }

    SubresourceLayout tight_layout;
    SubresourceLayout staging_layout;
    if (!publish || !validTextureSource(descriptor,
                                        source,
                                        tight_layout,
                                        staging_layout))
    {
        return MetalTransferStatus::invalid_argument;
    }

    auto texture = createPrivateTexture2D(mImpl->deviceHandle(), descriptor);
    if (!texture)
    {
        return MetalTransferStatus::resource_allocation_failed;
    }
    return mImpl->uploadTexture(descriptor,
                                source,
                                std::move(*texture),
                                std::move(publish));
}

MetalTransferStatus MetalTransferBatch::readbackBuffer(const MetalPrivateBuffer& source,
                                                       std::size_t               offset,
                                                       std::size_t               size,
                                                       PublishBufferReadback     publish)
{
    return mImpl == nullptr
               ? MetalTransferStatus::invalid_state
               : mImpl->readbackBuffer(source, offset, size, std::move(publish));
}

MetalTransferStatus MetalTransferBatch::readbackTexture2D(
    const MetalPrivateTexture2D& source,
    MetalTextureRegion            region,
    PublishTextureReadback        publish)
{
    return mImpl == nullptr
               ? MetalTransferStatus::invalid_state
               : mImpl->readbackTexture(source, region, std::move(publish));
}

std::optional<MetalFrameContext::CompletionAction> MetalTransferBatch::finish()
{
    return mImpl == nullptr ? std::nullopt : mImpl->finish();
}

void MetalTransferBatch::cancel() noexcept
{
    if (mImpl != nullptr)
    {
        mImpl->cancel();
    }
}

} // namespace firestorm::metal
