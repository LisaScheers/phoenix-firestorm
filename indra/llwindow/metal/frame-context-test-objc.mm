/**
 * @file frame-context-test-objc.mm
 * @brief Focused GPU tests for generation-safe Metal frame contexts.
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
#import <objc/runtime.h>

#include "llmetalframecontext.h"

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <optional>
#include <stdexcept>

@interface FSFailedCommandBuffer : NSObject

@property(nonatomic, copy, nullable) MTLCommandBufferHandler completionHandler;
@property(nonatomic) MTLCommandBufferStatus simulatedStatus;

- (void)addCompletedHandler:(MTLCommandBufferHandler)handler;
- (MTLCommandBufferStatus)status;
- (void)finishWithFailure;

@end

@implementation FSFailedCommandBuffer

- (BOOL)conformsToProtocol:(Protocol*)protocol
{
    return protocol_isEqual(protocol, @protocol(MTLCommandBuffer)) ||
        [super conformsToProtocol:protocol];
}

- (void)addCompletedHandler:(MTLCommandBufferHandler)handler
{
    self.completionHandler = handler;
}

- (MTLCommandBufferStatus)status
{
    return self.simulatedStatus;
}

- (void)finishWithFailure
{
    self.simulatedStatus = MTLCommandBufferStatusError;
    MTLCommandBufferHandler handler = self.completionHandler;
    self.completionHandler = nil;
    if (handler != nil)
    {
        handler((id<MTLCommandBuffer>)self);
    }
}

@end

namespace
{

int gFailures = 0;

void expect(bool condition, const char* expression, int line)
{
    if (!condition)
    {
        std::cerr << "FAIL line " << line << ": " << expression << '\n';
        ++gFailures;
    }
}

#define EXPECT(expression) expect(static_cast<bool>(expression), #expression, __LINE__)

using firestorm::metal::FrameToken;
using firestorm::metal::MetalFrameContext;

void publishLatest(std::atomic<std::uint64_t>& published, std::uint64_t serial)
{
    std::uint64_t observed = published.load(std::memory_order_relaxed);
    while (serial > observed &&
           !published.compare_exchange_weak(observed,
                                            serial,
                                            std::memory_order_release,
                                            std::memory_order_relaxed))
    {
    }
}

std::uint32_t readWord(id<MTLBuffer> buffer)
{
    std::uint32_t value = 0;
    std::memcpy(&value, buffer.contents, sizeof(value));
    return value;
}

void requireSignal(dispatch_semaphore_t semaphore, const char* operation)
{
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0)
    {
        std::cerr << "TIMEOUT waiting for " << operation << '\n';
        std::_Exit(EXIT_FAILURE);
    }
}

void testValidationAndCancel(id<MTLDevice> device)
{
    MetalFrameContext null_device(nullptr, 64);
    EXPECT(!null_device.valid());
    EXPECT(!null_device.tryBegin().has_value());

    MetalFrameContext zero_capacity((__bridge void*)device, 0);
    EXPECT(!zero_capacity.valid());

    NSObject* not_metal = [[NSObject alloc] init];
    MetalFrameContext wrong_device((__bridge void*)not_metal, 64);
    EXPECT(!wrong_device.valid());

    MetalFrameContext contexts((__bridge void*)device, 64);
    EXPECT(contexts.valid());

    const auto first = contexts.tryBegin();
    EXPECT(first.has_value());
    if (!first)
    {
        return;
    }

    const auto prefix = contexts.allocate(first->token, 4, 4);
    const auto aligned = contexts.allocate(first->token, 4, 16);
    EXPECT(prefix.has_value());
    EXPECT(aligned.has_value());
    EXPECT(prefix && prefix->offset == 0);
    EXPECT(aligned && aligned->offset == 16);
    EXPECT(!contexts.allocate(first->token, std::numeric_limits<std::size_t>::max()).has_value());
    EXPECT(!contexts.retire(first->token, nullptr));
    EXPECT(!contexts.submit(first->token, nullptr).has_value());
    EXPECT(!contexts.retire(first->token, (__bridge void*)not_metal));
    EXPECT(!contexts.submit(first->token, (__bridge void*)not_metal).has_value());

    const FrameToken wrong_generation{ first->token.slot, first->token.generation + 1 };
    id<MTLBuffer> resource = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command_buffer = [[device newCommandQueue] commandBuffer];
    EXPECT(!contexts.allocate(wrong_generation, 1).has_value());
    EXPECT(!contexts.retire(wrong_generation, (__bridge void*)resource));
    EXPECT(!contexts.submit(wrong_generation, (__bridge void*)command_buffer).has_value());
    EXPECT(!contexts.cancel(wrong_generation));

    id<MTLCommandBuffer> completed_buffer = [[device newCommandQueue] commandBuffer];
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    [completed_buffer addCompletedHandler:^(id<MTLCommandBuffer>) {
        dispatch_semaphore_signal(completed);
    }];
    [completed_buffer commit];
    requireSignal(completed, "completed-buffer rejection setup");
    EXPECT(completed_buffer.status == MTLCommandBufferStatusCompleted);
    EXPECT(!contexts.submit(first->token, (__bridge void*)completed_buffer).has_value());
    EXPECT(contexts.allocate(first->token, 1).has_value());

    EXPECT(contexts.cancel(first->token));
    EXPECT(!contexts.cancel(first->token));
    EXPECT(!contexts.allocate(first->token, 1).has_value());
    EXPECT(!contexts.retire(first->token, (__bridge void*)resource));

    const auto reused = contexts.tryBegin();
    EXPECT(reused.has_value());
    if (reused)
    {
        EXPECT(reused->token.slot == first->token.slot);
        EXPECT(reused->token.generation > first->token.generation);
        const auto allocation = contexts.allocate(reused->token, 4, 16);
        EXPECT(allocation.has_value());
        EXPECT(allocation && allocation->offset == 0);
        EXPECT(contexts.cancel(reused->token));
    }
}

void testThreeInFlightAndOutOfOrderCompletion(id<MTLDevice> device)
{
    MetalFrameContext contexts((__bridge void*)device, 256);
    EXPECT(contexts.valid());

    const auto frame_a = contexts.tryBegin();
    const auto frame_b = contexts.tryBegin();
    const auto frame_c = contexts.tryBegin();
    EXPECT(frame_a.has_value());
    EXPECT(frame_b.has_value());
    EXPECT(frame_c.has_value());
    EXPECT(!contexts.tryBegin().has_value());
    if (!frame_a || !frame_b || !frame_c)
    {
        return;
    }

    const auto allocation_a = contexts.allocate(frame_a->token, sizeof(std::uint32_t), 16);
    const auto allocation_b = contexts.allocate(frame_b->token, sizeof(std::uint32_t), 16);
    const auto allocation_c = contexts.allocate(frame_c->token, sizeof(std::uint32_t), 16);
    EXPECT(allocation_a.has_value());
    EXPECT(allocation_b.has_value());
    EXPECT(allocation_c.has_value());
    if (!allocation_a || !allocation_b || !allocation_c)
    {
        return;
    }

    constexpr std::uint32_t kPatternA = 0x11223344;
    constexpr std::uint32_t kPatternB = 0x55667788;
    constexpr std::uint32_t kPatternC = 0x99aabbcc;
    std::memcpy(allocation_a->bytes, &kPatternA, sizeof(kPatternA));
    std::memcpy(allocation_b->bytes, &kPatternB, sizeof(kPatternB));
    std::memcpy(allocation_c->bytes, &kPatternC, sizeof(kPatternC));

    id<MTLBuffer> source_a = (__bridge id<MTLBuffer>)frame_a->buffer;
    id<MTLBuffer> source_b = (__bridge id<MTLBuffer>)frame_b->buffer;
    id<MTLBuffer> source_c = (__bridge id<MTLBuffer>)frame_c->buffer;
    id<MTLBuffer> destination_a = [device newBufferWithLength:sizeof(std::uint32_t)
                                                       options:MTLResourceStorageModeShared];
    id<MTLBuffer> destination_b = [device newBufferWithLength:sizeof(std::uint32_t)
                                                       options:MTLResourceStorageModeShared];
    id<MTLBuffer> destination_c = [device newBufferWithLength:sizeof(std::uint32_t)
                                                       options:MTLResourceStorageModeShared];

    id<MTLBuffer> retired_a = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> retired_b = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> retired_c = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    __weak id<MTLBuffer> weak_retired_a = retired_a;
    __weak id<MTLBuffer> weak_retired_b = retired_b;
    __weak id<MTLBuffer> weak_retired_c = retired_c;
    EXPECT(contexts.retire(frame_a->token, (__bridge void*)retired_a));
    EXPECT(contexts.retire(frame_b->token, (__bridge void*)retired_b));
    EXPECT(contexts.retire(frame_c->token, (__bridge void*)retired_c));
    retired_a = nil;
    retired_b = nil;
    retired_c = nil;
    EXPECT(weak_retired_a != nil);
    EXPECT(weak_retired_b != nil);
    EXPECT(weak_retired_c != nil);

    id<MTLCommandQueue> queue_a = [device newCommandQueue];
    id<MTLCommandQueue> queue_b = [device newCommandQueue];
    id<MTLCommandQueue> queue_c = [device newCommandQueue];
    id<MTLSharedEvent> gate_a = [device newSharedEvent];
    id<MTLSharedEvent> gate_b = [device newSharedEvent];
    id<MTLSharedEvent> gate_c = [device newSharedEvent];
    id<MTLCommandBuffer> command_a = [queue_a commandBuffer];
    id<MTLCommandBuffer> command_b = [queue_b commandBuffer];
    id<MTLCommandBuffer> command_c = [queue_c commandBuffer];
    EXPECT(queue_a != nil && queue_b != nil && queue_c != nil);
    EXPECT(gate_a != nil && gate_b != nil && gate_c != nil);
    EXPECT(command_a != nil && command_b != nil && command_c != nil);
    if (command_a == nil || command_b == nil || command_c == nil ||
        gate_a == nil || gate_b == nil || gate_c == nil)
    {
        return;
    }

    [command_a encodeWaitForEvent:gate_a value:1];
    id<MTLBlitCommandEncoder> blit_a = [command_a blitCommandEncoder];
    [blit_a copyFromBuffer:source_a
              sourceOffset:allocation_a->offset
                  toBuffer:destination_a
         destinationOffset:0
                      size:sizeof(std::uint32_t)];
    [blit_a endEncoding];

    [command_b encodeWaitForEvent:gate_b value:1];
    id<MTLBlitCommandEncoder> blit_b = [command_b blitCommandEncoder];
    [blit_b copyFromBuffer:source_b
              sourceOffset:allocation_b->offset
                  toBuffer:destination_b
         destinationOffset:0
                      size:sizeof(std::uint32_t)];
    [blit_b endEncoding];

    [command_c encodeWaitForEvent:gate_c value:1];
    id<MTLBlitCommandEncoder> blit_c = [command_c blitCommandEncoder];
    [blit_c copyFromBuffer:source_c
              sourceOffset:allocation_c->offset
                  toBuffer:destination_c
         destinationOffset:0
                      size:sizeof(std::uint32_t)];
    [blit_c endEncoding];

    std::atomic<std::uint64_t> published_serial{ 0 };
    std::atomic<std::uint64_t> observed_a{ 0 };
    std::atomic<std::uint64_t> observed_b{ 0 };
    std::atomic<std::uint64_t> observed_c{ 0 };
    std::atomic<bool> c_slot_available_in_action{ false };
    std::atomic<bool> c_retirement_gone_in_action{ false };
    dispatch_semaphore_t done_a = dispatch_semaphore_create(0);
    dispatch_semaphore_t done_b = dispatch_semaphore_create(0);
    dispatch_semaphore_t done_c = dispatch_semaphore_create(0);

    const auto serial_a = contexts.submit(
        frame_a->token,
        (__bridge void*)command_a,
        [&](std::uint64_t serial) {
            observed_a.store(serial, std::memory_order_relaxed);
            publishLatest(published_serial, serial);
            dispatch_semaphore_signal(done_a);
        });
    const auto serial_b = contexts.submit(
        frame_b->token,
        (__bridge void*)command_b,
        [&](std::uint64_t serial) {
            observed_b.store(serial, std::memory_order_relaxed);
            publishLatest(published_serial, serial);
            dispatch_semaphore_signal(done_b);
        });
    const auto serial_c = contexts.submit(
        frame_c->token,
        (__bridge void*)command_c,
        [&](std::uint64_t serial) {
            observed_c.store(serial, std::memory_order_relaxed);
            publishLatest(published_serial, serial);
            c_retirement_gone_in_action.store(weak_retired_c == nil, std::memory_order_relaxed);
            const auto callback_lease = contexts.tryBegin();
            if (callback_lease && callback_lease->token.slot == frame_c->token.slot)
            {
                c_slot_available_in_action.store(contexts.cancel(callback_lease->token),
                                                 std::memory_order_relaxed);
            }
            dispatch_semaphore_signal(done_c);
            throw std::runtime_error("completion actions cannot strand reclaimed contexts");
        });

    EXPECT(serial_a == std::optional<std::uint64_t>(1));
    EXPECT(serial_b == std::optional<std::uint64_t>(2));
    EXPECT(serial_c == std::optional<std::uint64_t>(3));
    EXPECT(!contexts.submit(frame_a->token, (__bridge void*)command_a).has_value());
    EXPECT(!contexts.cancel(frame_a->token));

    [command_a commit];
    [command_b commit];
    [command_c commit];
    EXPECT(!contexts.tryBegin().has_value());

    gate_c.signaledValue = 1;
    requireSignal(done_c, "third frame completion");
    EXPECT(command_c.status == MTLCommandBufferStatusCompleted);
    EXPECT(readWord(destination_c) == kPatternC);
    EXPECT(weak_retired_c == nil);
    EXPECT(weak_retired_a != nil);
    EXPECT(weak_retired_b != nil);
    EXPECT(c_retirement_gone_in_action.load(std::memory_order_relaxed));
    EXPECT(c_slot_available_in_action.load(std::memory_order_relaxed));
    EXPECT(published_serial.load(std::memory_order_acquire) == 3);
    EXPECT(!contexts.allocate(frame_c->token, 1).has_value());
    EXPECT(!contexts.cancel(frame_c->token));

    gate_a.signaledValue = 1;
    requireSignal(done_a, "first frame completion");
    EXPECT(command_a.status == MTLCommandBufferStatusCompleted);
    EXPECT(readWord(destination_a) == kPatternA);
    EXPECT(weak_retired_a == nil);
    EXPECT(weak_retired_b != nil);
    EXPECT(published_serial.load(std::memory_order_acquire) == 3);

    gate_b.signaledValue = 1;
    requireSignal(done_b, "second frame completion");
    EXPECT(command_b.status == MTLCommandBufferStatusCompleted);
    EXPECT(readWord(destination_b) == kPatternB);
    EXPECT(weak_retired_b == nil);
    EXPECT(observed_a.load(std::memory_order_relaxed) == 1);
    EXPECT(observed_b.load(std::memory_order_relaxed) == 2);
    EXPECT(observed_c.load(std::memory_order_relaxed) == 3);
    EXPECT(published_serial.load(std::memory_order_acquire) == 3);
}

void testFailedSubmissionReclaimsWithoutPublishing(id<MTLDevice> device)
{
    MetalFrameContext contexts((__bridge void*)device, 64);
    const auto frame = contexts.tryBegin();
    EXPECT(frame.has_value());
    if (!frame)
    {
        return;
    }

    id<MTLBuffer> retired = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    __weak id<MTLBuffer> weak_retired = retired;
    EXPECT(contexts.retire(frame->token, (__bridge void*)retired));
    retired = nil;
    EXPECT(weak_retired != nil);

    FSFailedCommandBuffer* failed = [[FSFailedCommandBuffer alloc] init];
    failed.simulatedStatus = MTLCommandBufferStatusNotEnqueued;
    std::atomic<bool> published{ false };
    const auto serial = contexts.submit(
        frame->token,
        (__bridge void*)failed,
        [&](std::uint64_t) { published.store(true, std::memory_order_relaxed); });
    EXPECT(serial == std::optional<std::uint64_t>(1));
    [failed finishWithFailure];
    EXPECT(!published.load(std::memory_order_relaxed));
    EXPECT(weak_retired == nil);
    EXPECT(!contexts.allocate(frame->token, 1).has_value());
    EXPECT(!contexts.cancel(frame->token));

    // The failed context is reusable, but its success-only publication did not run.
    const auto reclaimed = contexts.tryBegin();
    EXPECT(reclaimed.has_value());
    if (reclaimed)
    {
        EXPECT(reclaimed->token.slot == frame->token.slot);
        EXPECT(reclaimed->token.generation > frame->token.generation);
        EXPECT(contexts.cancel(reclaimed->token));
    }
}

} // namespace

int main()
{
    @autoreleasepool
    {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        EXPECT(device != nil);
        if (device == nil)
        {
            return EXIT_FAILURE;
        }

        testValidationAndCancel(device);
        testThreeInFlightAndOutOfOrderCompletion(device);
        testFailedSubmissionReclaimsWithoutPublishing(device);
    }

    if (gFailures != 0)
    {
        std::cerr << gFailures << " Metal frame context test(s) failed\n";
        return EXIT_FAILURE;
    }

    std::cout << "PASS Metal frame contexts\n";
    return EXIT_SUCCESS;
}
