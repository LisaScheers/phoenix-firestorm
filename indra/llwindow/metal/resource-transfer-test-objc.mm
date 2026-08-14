/**
 * @file resource-transfer-test-objc.mm
 * @brief Focused GPU tests for bounded private-resource transfers.
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

#include "llmetalresource.h"
#include "llmetaltransfer.h"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

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

using firestorm::metal::MetalBufferReadback;
using firestorm::metal::MetalByteView;
using firestorm::metal::MetalFrameContext;
using firestorm::metal::MetalFrameLease;
using firestorm::metal::MetalPrivateBuffer;
using firestorm::metal::MetalPrivateTexture2D;
using firestorm::metal::MetalTexture2DDescriptor;
using firestorm::metal::MetalTextureReadback;
using firestorm::metal::MetalTextureRegion;
using firestorm::metal::MetalTextureUpload2D;
using firestorm::metal::MetalTextureUsage;
using firestorm::metal::MetalTransferBatch;
using firestorm::metal::MetalTransferStatus;
using firestorm::metal::PixelFormat;
using firestorm::metal::createPrivateTexture2D;
using firestorm::metal::hasUsage;

constexpr std::size_t TEXTURE_WIDTH            = 2;
constexpr std::size_t TEXTURE_HEIGHT           = 2;
constexpr std::size_t BYTES_PER_PIXEL          = 4;
constexpr std::size_t ACTIVE_TEXTURE_ROW_BYTES = TEXTURE_WIDTH * BYTES_PER_PIXEL;
constexpr std::size_t SOURCE_TEXTURE_ROW_BYTES = ACTIVE_TEXTURE_ROW_BYTES + 3;

constexpr std::array<std::uint8_t, 16> BUFFER_SOURCE{
    0x00, 0x11, 0x22, 0x33,
    0x44, 0x55, 0x66, 0x77,
    0x88, 0x99, 0xaa, 0xbb,
    0xcc, 0xdd, 0xee, 0xff,
};

// Each active row is two RGBA8 pixels followed by three bytes that must not be
// uploaded. Distinct corner colors make both row orientation and x order exact.
constexpr std::array<std::uint8_t, SOURCE_TEXTURE_ROW_BYTES * TEXTURE_HEIGHT>
    TEXTURE_SOURCE{
        255, 0,   0,   255, 0,   255, 0,   255, 0xa1, 0xa2, 0xa3,
        0,   0,   255, 255, 255, 255, 255, 255, 0xb1, 0xb2, 0xb3,
    };

constexpr std::array<std::uint8_t, ACTIVE_TEXTURE_ROW_BYTES * TEXTURE_HEIGHT>
    EXPECTED_TEXTURE{
        255, 0, 0, 255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };

MetalByteView byteView(const std::uint8_t* data, std::size_t size)
{
    return { reinterpret_cast<const std::byte*>(data), size };
}

std::string toString(NSString* value)
{
    if (value == nil)
    {
        return {};
    }

    const char* utf8 = value.UTF8String;
    return utf8 == nullptr ? std::string() : std::string(utf8);
}

std::string commandError(id<MTLCommandBuffer> command_buffer)
{
    if (command_buffer == nil || command_buffer.error == nil)
    {
        return {};
    }

    return toString(command_buffer.error.localizedDescription);
}

void requireSignal(dispatch_semaphore_t semaphore,
                   id<MTLCommandBuffer> command_buffer,
                   const char* operation)
{
    if (dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0)
    {
        return;
    }

    std::cerr << "TIMEOUT waiting for " << operation
              << " status=" << static_cast<unsigned long>(command_buffer.status)
              << " error=\"" << commandError(command_buffer) << "\"\n";
    std::_Exit(EXIT_FAILURE);
}

std::size_t byteValue(std::byte value)
{
    return std::to_integer<std::size_t>(value);
}

void expectBytes(const std::vector<std::byte>& actual,
                 const std::uint8_t* expected,
                 std::size_t size,
                 const char* label)
{
    EXPECT(actual.size() == size);
    if (actual.size() != size)
    {
        return;
    }

    for (std::size_t offset = 0; offset < size; ++offset)
    {
        if (byteValue(actual[offset]) != expected[offset])
        {
            std::cerr << "FAIL " << label << " offset=" << offset
                      << " expected=" << static_cast<unsigned>(expected[offset])
                      << " actual=" << byteValue(actual[offset]) << '\n';
            ++gFailures;
            return;
        }
    }
}

struct UploadedResources
{
    MetalPrivateBuffer    buffer;
    MetalPrivateTexture2D texture;
    std::uint64_t         submissionSerial = 0;
};

struct UploadPublications
{
    std::mutex                             mutex;
    std::optional<MetalPrivateBuffer>      buffer;
    std::optional<MetalPrivateTexture2D>   texture;
    std::vector<std::string>               order;
    std::vector<std::uint64_t>             serials;
    dispatch_semaphore_t                   done = dispatch_semaphore_create(0);
};

std::size_t publicationCount(UploadPublications& publications)
{
    std::lock_guard<std::mutex> lock(publications.mutex);
    return publications.order.size();
}

std::optional<UploadedResources> uploadResources(id<MTLDevice> device,
                                                 id<MTLCommandQueue> queue,
                                                 MetalFrameContext& frames)
{
    const auto lease = frames.tryBegin();
    EXPECT(lease.has_value());
    if (!lease)
    {
        return std::nullopt;
    }

    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    EXPECT(command_buffer != nil);
    if (command_buffer == nil)
    {
        EXPECT(frames.cancel(lease->token));
        return std::nullopt;
    }
    command_buffer.label = @"Firestorm private resource upload test";

    UploadPublications publications;
    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             0);
    EXPECT(batch.valid());

    const MetalTransferStatus buffer_status = batch.uploadPrivateBuffer(
        byteView(BUFFER_SOURCE.data(), BUFFER_SOURCE.size()),
        "Firestorm exact private buffer",
        [&](std::uint64_t serial, MetalPrivateBuffer buffer) {
            bool finished = false;
            {
                std::lock_guard<std::mutex> lock(publications.mutex);
                publications.buffer = std::move(buffer);
                publications.order.emplace_back("buffer");
                publications.serials.push_back(serial);
                finished = publications.order.size() == 2;
            }
            if (finished)
            {
                dispatch_semaphore_signal(publications.done);
            }
        });
    EXPECT(buffer_status == MetalTransferStatus::encoded);

    MetalTexture2DDescriptor texture_descriptor;
    texture_descriptor.format    = PixelFormat::rgba8_unorm;
    texture_descriptor.width     = static_cast<std::uint32_t>(TEXTURE_WIDTH);
    texture_descriptor.height    = static_cast<std::uint32_t>(TEXTURE_HEIGHT);
    texture_descriptor.mipLevels = 1;
    texture_descriptor.usage     = MetalTextureUsage::shader_read;
    texture_descriptor.label     = "Firestorm exact private texture";

    const MetalTextureUpload2D texture_upload{
        byteView(TEXTURE_SOURCE.data(), TEXTURE_SOURCE.size()),
        SOURCE_TEXTURE_ROW_BYTES,
    };
    const MetalTransferStatus texture_status = batch.uploadPrivateTexture2D(
        texture_descriptor,
        texture_upload,
        [&](std::uint64_t serial, MetalPrivateTexture2D texture) {
            bool finished = false;
            {
                std::lock_guard<std::mutex> lock(publications.mutex);
                publications.texture = std::move(texture);
                publications.order.emplace_back("texture");
                publications.serials.push_back(serial);
                finished = publications.order.size() == 2;
            }
            if (finished)
            {
                dispatch_semaphore_signal(publications.done);
            }
        });
    EXPECT(texture_status == MetalTransferStatus::encoded);

    auto completion = batch.finish();
    EXPECT(completion.has_value());
    EXPECT(!batch.finish().has_value());
    if (!completion)
    {
        EXPECT(frames.cancel(lease->token));
        return std::nullopt;
    }

    EXPECT(publicationCount(publications) == 0);
    const auto serial = frames.submit(
        lease->token,
        (__bridge void*)command_buffer,
        std::move(*completion));
    EXPECT(serial.has_value());
    if (!serial)
    {
        EXPECT(frames.cancel(lease->token));
        return std::nullopt;
    }

    EXPECT(publicationCount(publications) == 0);
    [command_buffer commit];
    requireSignal(publications.done, command_buffer, "private resource upload publication");

    std::lock_guard<std::mutex> lock(publications.mutex);
    EXPECT(publications.order == std::vector<std::string>({ "buffer", "texture" }));
    EXPECT(publications.serials == std::vector<std::uint64_t>({ *serial, *serial }));
    EXPECT(publications.buffer.has_value());
    EXPECT(publications.texture.has_value());
    if (!publications.buffer || !publications.texture)
    {
        return std::nullopt;
    }

    return UploadedResources{ *publications.buffer, *publications.texture, *serial };
}

struct ReadbackPublications
{
    std::mutex                           mutex;
    std::optional<MetalBufferReadback>   buffer;
    std::optional<MetalTextureReadback>  texture;
    std::vector<std::string>             order;
    std::vector<std::uint64_t>           serials;
    dispatch_semaphore_t                 done = dispatch_semaphore_create(0);
};

std::size_t publicationCount(ReadbackPublications& publications)
{
    std::lock_guard<std::mutex> lock(publications.mutex);
    return publications.order.size();
}

void validateTextureReadback(const MetalTextureReadback& readback)
{
    EXPECT(readback.format == PixelFormat::rgba8_unorm);
    EXPECT(readback.region.x == 0);
    EXPECT(readback.region.y == 0);
    EXPECT(readback.region.width == TEXTURE_WIDTH);
    EXPECT(readback.region.height == TEXTURE_HEIGHT);
    EXPECT(readback.region.mipLevel == 0);
    EXPECT(readback.region.slice == 0);
    EXPECT(readback.bytesPerRow >= ACTIVE_TEXTURE_ROW_BYTES);
    EXPECT(readback.bytesPerRow % BYTES_PER_PIXEL == 0);
    EXPECT(readback.bytesPerImage == readback.bytesPerRow * TEXTURE_HEIGHT);
    EXPECT(readback.bytes.size() == readback.bytesPerImage);
    if (readback.bytesPerRow < ACTIVE_TEXTURE_ROW_BYTES ||
        readback.bytes.size() < readback.bytesPerImage)
    {
        return;
    }

    for (std::size_t y = 0; y < TEXTURE_HEIGHT; ++y)
    {
        for (std::size_t x = 0; x < ACTIVE_TEXTURE_ROW_BYTES; ++x)
        {
            const std::size_t actual_offset = y * readback.bytesPerRow + x;
            const std::size_t expected_offset = y * ACTIVE_TEXTURE_ROW_BYTES + x;
            if (byteValue(readback.bytes[actual_offset]) != EXPECTED_TEXTURE[expected_offset])
            {
                std::cerr << "FAIL private texture readback pixel_byte=(" << x << ',' << y
                          << ") row_order=top-to-bottom expected="
                          << static_cast<unsigned>(EXPECTED_TEXTURE[expected_offset])
                          << " actual=" << byteValue(readback.bytes[actual_offset])
                          << " bytes_per_row=" << readback.bytesPerRow << '\n';
                ++gFailures;
                return;
            }
        }
    }
}

void readbackResources(id<MTLDevice> device,
                       id<MTLCommandQueue> queue,
                       MetalFrameContext& frames,
                       const UploadedResources& resources)
{
    const auto lease = frames.tryBegin();
    EXPECT(lease.has_value());
    if (!lease)
    {
        return;
    }

    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    id<MTLSharedEvent> gate = [device newSharedEvent];
    EXPECT(command_buffer != nil);
    EXPECT(gate != nil);
    if (command_buffer == nil || gate == nil)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }
    command_buffer.label = @"Firestorm private resource readback test";
    [command_buffer encodeWaitForEvent:gate value:1];

    ReadbackPublications publications;
    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             1024);
    EXPECT(batch.valid());

    const MetalTransferStatus buffer_status = batch.readbackBuffer(
        resources.buffer,
        4,
        8,
        [&](std::uint64_t serial, MetalBufferReadback readback) {
            bool finished = false;
            {
                std::lock_guard<std::mutex> lock(publications.mutex);
                publications.buffer = std::move(readback);
                publications.order.emplace_back("buffer");
                publications.serials.push_back(serial);
                finished = publications.order.size() == 2;
            }
            if (finished)
            {
                dispatch_semaphore_signal(publications.done);
            }
        });
    EXPECT(buffer_status == MetalTransferStatus::encoded);

    const MetalTextureRegion region{
        0,
        0,
        static_cast<std::uint32_t>(TEXTURE_WIDTH),
        static_cast<std::uint32_t>(TEXTURE_HEIGHT),
        0,
        0,
    };
    const MetalTransferStatus texture_status = batch.readbackTexture2D(
        resources.texture,
        region,
        [&](std::uint64_t serial, MetalTextureReadback readback) {
            bool finished = false;
            {
                std::lock_guard<std::mutex> lock(publications.mutex);
                publications.texture = std::move(readback);
                publications.order.emplace_back("texture");
                publications.serials.push_back(serial);
                finished = publications.order.size() == 2;
            }
            if (finished)
            {
                dispatch_semaphore_signal(publications.done);
            }
        });
    EXPECT(texture_status == MetalTransferStatus::encoded);

    auto completion = batch.finish();
    EXPECT(completion.has_value());
    EXPECT(!batch.finish().has_value());
    if (!completion)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    const auto serial = frames.submit(
        lease->token,
        (__bridge void*)command_buffer,
        std::move(*completion));
    EXPECT(serial.has_value());
    if (!serial)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    [command_buffer commit];
    EXPECT(publicationCount(publications) == 0);
    gate.signaledValue = 1;
    requireSignal(publications.done, command_buffer, "private resource readback publication");

    std::lock_guard<std::mutex> lock(publications.mutex);
    EXPECT(publications.order == std::vector<std::string>({ "buffer", "texture" }));
    EXPECT(*serial > resources.submissionSerial);
    EXPECT(publications.serials == std::vector<std::uint64_t>({ *serial, *serial }));
    EXPECT(publications.buffer.has_value());
    EXPECT(publications.texture.has_value());
    if (publications.buffer)
    {
        EXPECT(publications.buffer->sourceOffset == 4);
        expectBytes(publications.buffer->bytes,
                    BUFFER_SOURCE.data() + 4,
                    8,
                    "private buffer readback");
    }
    if (publications.texture)
    {
        validateTextureReadback(*publications.texture);
    }
}

void testConcreteResourceDescriptors(id<MTLDevice> device)
{
    MetalTexture2DDescriptor color_descriptor;
    color_descriptor.format    = PixelFormat::rgba8_unorm;
    color_descriptor.width     = 3;
    color_descriptor.height    = 2;
    color_descriptor.mipLevels = 1;
    color_descriptor.usage = MetalTextureUsage::render_target |
                             MetalTextureUsage::shader_read;
    color_descriptor.label = "Firestorm empty color attachment";

    const auto color = createPrivateTexture2D((__bridge void*)device,
                                              color_descriptor);
    EXPECT(color.has_value());
    if (color)
    {
        EXPECT(color->valid());
        EXPECT(color->format() == PixelFormat::rgba8_unorm);
        EXPECT(color->width() == 3);
        EXPECT(color->height() == 2);
        EXPECT(color->mipLevels() == 1);
        EXPECT(hasUsage(color->usage(), MetalTextureUsage::render_target));
        EXPECT(hasUsage(color->usage(), MetalTextureUsage::shader_read));

        id<MTLTexture> native = (__bridge id<MTLTexture>)color->nativeHandle();
        EXPECT(native != nil);
        EXPECT(native.storageMode == MTLStorageModePrivate);
        EXPECT(native.pixelFormat == MTLPixelFormatRGBA8Unorm);
        EXPECT((native.usage & MTLTextureUsageRenderTarget) != 0);
        EXPECT((native.usage & MTLTextureUsageShaderRead) != 0);
    }

    MetalTexture2DDescriptor depth_descriptor;
    depth_descriptor.format    = PixelFormat::depth32_float;
    depth_descriptor.width     = 3;
    depth_descriptor.height    = 2;
    depth_descriptor.mipLevels = 1;
    depth_descriptor.usage     = MetalTextureUsage::render_target;
    depth_descriptor.label     = "Firestorm empty depth attachment";

    const auto depth = createPrivateTexture2D((__bridge void*)device,
                                              depth_descriptor);
    EXPECT(depth.has_value());
    if (depth)
    {
        EXPECT(depth->valid());
        EXPECT(depth->format() == PixelFormat::depth32_float);
        EXPECT(depth->usage() == MetalTextureUsage::render_target);

        id<MTLTexture> native = (__bridge id<MTLTexture>)depth->nativeHandle();
        EXPECT(native != nil);
        EXPECT(native.storageMode == MTLStorageModePrivate);
        EXPECT(native.pixelFormat == MTLPixelFormatDepth32Float);
        EXPECT((native.usage & MTLTextureUsageRenderTarget) != 0);
    }

    EXPECT(!createPrivateTexture2D(nullptr, color_descriptor).has_value());
    NSObject* not_a_device = [[NSObject alloc] init];
    EXPECT(!createPrivateTexture2D((__bridge void*)not_a_device,
                                  color_descriptor).has_value());
}

void testInvalidArguments(id<MTLDevice> device,
                          id<MTLCommandQueue> queue,
                          const UploadedResources& resources)
{
    MetalFrameContext frames((__bridge void*)device, 64);
    const auto lease = frames.tryBegin();
    EXPECT(lease.has_value());
    if (!lease)
    {
        return;
    }

    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    EXPECT(command_buffer != nil);
    if (command_buffer == nil)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             1024);
    EXPECT(batch.valid());
    std::atomic<unsigned> callbacks{ 0 };

    EXPECT(batch.readbackBuffer(
               resources.buffer,
               resources.buffer.size() - 1,
               2,
               [&](std::uint64_t, MetalBufferReadback) { ++callbacks; }) ==
           MetalTransferStatus::invalid_argument);
    EXPECT(batch.readbackBuffer(
               resources.buffer,
               1,
               4,
               [&](std::uint64_t, MetalBufferReadback) { ++callbacks; }) ==
           MetalTransferStatus::invalid_argument);

    MetalTextureRegion out_of_bounds{
        1,
        0,
        2,
        1,
        0,
        0,
    };
    EXPECT(batch.readbackTexture2D(
               resources.texture,
               out_of_bounds,
               [&](std::uint64_t, MetalTextureReadback) { ++callbacks; }) ==
           MetalTransferStatus::invalid_argument);

    MetalTextureRegion wrong_slice{
        0,
        0,
        1,
        1,
        0,
        1,
    };
    EXPECT(batch.readbackTexture2D(
               resources.texture,
               wrong_slice,
               [&](std::uint64_t, MetalTextureReadback) { ++callbacks; }) ==
           MetalTransferStatus::invalid_argument);

    MetalPrivateBuffer empty_buffer;
    EXPECT(batch.readbackBuffer(
               empty_buffer,
               0,
               1,
               [&](std::uint64_t, MetalBufferReadback) { ++callbacks; }) ==
           MetalTransferStatus::invalid_argument);

    batch.cancel();
    EXPECT(!batch.valid());
    EXPECT(callbacks.load(std::memory_order_relaxed) == 0);
    EXPECT(!frames.cancel(lease->token));
}

void testStagingExhaustionAndCancel(id<MTLDevice> device,
                                    id<MTLCommandQueue> queue)
{
    MetalFrameContext frames((__bridge void*)device, 16);
    const auto lease = frames.tryBegin();
    EXPECT(lease.has_value());
    if (!lease)
    {
        return;
    }

    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    EXPECT(command_buffer != nil);
    if (command_buffer == nil)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    std::atomic<unsigned> callbacks{ 0 };
    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             0);
    EXPECT(batch.valid());
    EXPECT(batch.uploadPrivateBuffer(
               byteView(BUFFER_SOURCE.data(), 12),
               "Firestorm staging budget first upload",
               [&](std::uint64_t, MetalPrivateBuffer) { ++callbacks; }) ==
           MetalTransferStatus::encoded);
    EXPECT(batch.uploadPrivateBuffer(
               byteView(BUFFER_SOURCE.data(), 8),
               "Firestorm staging budget rejected upload",
               [&](std::uint64_t, MetalPrivateBuffer) { ++callbacks; }) ==
           MetalTransferStatus::staging_full);

    batch.cancel();
    EXPECT(callbacks.load(std::memory_order_relaxed) == 0);
    EXPECT(!frames.cancel(lease->token));

    const auto reused = frames.tryBegin();
    EXPECT(reused.has_value());
    if (reused)
    {
        EXPECT(reused->token.slot == lease->token.slot);
        EXPECT(reused->token.generation > lease->token.generation);
        EXPECT(frames.cancel(reused->token));
    }
}

void testReadbackBudgetAndOneShotFinish(id<MTLDevice> device,
                                        id<MTLCommandQueue> queue,
                                        const UploadedResources& resources)
{
    MetalFrameContext frames((__bridge void*)device, 64);
    const auto lease = frames.tryBegin();
    EXPECT(lease.has_value());
    if (!lease)
    {
        return;
    }

    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    EXPECT(command_buffer != nil);
    if (command_buffer == nil)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    std::atomic<unsigned> callbacks{ 0 };
    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             7);
    EXPECT(batch.valid());
    EXPECT(batch.readbackBuffer(
               resources.buffer,
               0,
               4,
               [&](std::uint64_t, MetalBufferReadback) { ++callbacks; }) ==
           MetalTransferStatus::encoded);
    EXPECT(batch.readbackBuffer(
               resources.buffer,
               4,
               4,
               [&](std::uint64_t, MetalBufferReadback) { ++callbacks; }) ==
           MetalTransferStatus::readback_budget_exceeded);

    auto completion = batch.finish();
    EXPECT(completion.has_value());
    EXPECT(!batch.finish().has_value());
    EXPECT(batch.readbackBuffer(
               resources.buffer,
               0,
               1,
               [&](std::uint64_t, MetalBufferReadback) { ++callbacks; }) ==
           MetalTransferStatus::invalid_state);

    completion.reset();
    EXPECT(callbacks.load(std::memory_order_relaxed) == 0);
    EXPECT(frames.cancel(lease->token));
}

void testInvalidBatchDevice(id<MTLDevice> device, id<MTLCommandQueue> queue)
{
    MetalFrameContext frames((__bridge void*)device, 64);
    const auto lease = frames.tryBegin();
    EXPECT(lease.has_value());
    if (!lease)
    {
        return;
    }

    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    EXPECT(command_buffer != nil);
    if (command_buffer == nil)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    MetalTransferBatch batch(nullptr,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             64);
    EXPECT(!batch.valid());
    EXPECT(batch.uploadPrivateBuffer(
               byteView(BUFFER_SOURCE.data(), 4),
               "Firestorm invalid-device upload",
               {}) == MetalTransferStatus::invalid_state);
    batch.cancel();
    EXPECT(!frames.cancel(lease->token));
}

void testLeaseBinding(id<MTLDevice> device, id<MTLCommandQueue> queue)
{
    MetalFrameContext first_frames((__bridge void*)device, 64);
    MetalFrameContext second_frames((__bridge void*)device, 64);
    const auto first_lease = first_frames.tryBegin();
    const auto second_lease = second_frames.tryBegin();
    EXPECT(first_lease.has_value());
    EXPECT(second_lease.has_value());
    if (!first_lease || !second_lease)
    {
        if (first_lease)
        {
            EXPECT(first_frames.cancel(first_lease->token));
        }
        if (second_lease)
        {
            EXPECT(second_frames.cancel(second_lease->token));
        }
        return;
    }
    EXPECT(first_lease->token == second_lease->token);

    id<MTLCommandBuffer> cross_context_command = [queue commandBuffer];
    EXPECT(cross_context_command != nil);
    if (cross_context_command == nil)
    {
        EXPECT(first_frames.cancel(first_lease->token));
        return;
    }

    {
        MetalTransferBatch cross_context((__bridge void*)device,
                                         second_frames,
                                         *first_lease,
                                         (__bridge void*)cross_context_command,
                                         0);
        EXPECT(!cross_context.valid());
        cross_context.cancel();
    }
    EXPECT(first_frames.cancel(first_lease->token));
    EXPECT(second_frames.cancel(second_lease->token));

    const auto exact_lease = first_frames.tryBegin();
    EXPECT(exact_lease.has_value());
    if (!exact_lease)
    {
        return;
    }

    id<MTLBuffer> unrelated_buffer =
        [device newBufferWithLength:exact_lease->capacity
                            options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> forged_command = [queue commandBuffer];
    EXPECT(unrelated_buffer != nil);
    EXPECT(forged_command != nil);
    if (unrelated_buffer == nil || forged_command == nil)
    {
        EXPECT(first_frames.cancel(exact_lease->token));
        return;
    }

    MetalFrameLease forged_lease = *exact_lease;
    forged_lease.buffer = (__bridge void*)unrelated_buffer;
    {
        MetalTransferBatch forged((__bridge void*)device,
                                  first_frames,
                                  forged_lease,
                                  (__bridge void*)forged_command,
                                  0);
        EXPECT(!forged.valid());
        forged.cancel();
    }
    EXPECT(first_frames.cancel(exact_lease->token));
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

        id<MTLCommandQueue> queue = [device newCommandQueue];
        EXPECT(queue != nil);
        if (queue == nil)
        {
            return EXIT_FAILURE;
        }

        testConcreteResourceDescriptors(device);

        MetalFrameContext frames((__bridge void*)device, 1024);
        EXPECT(frames.valid());
        const auto resources = uploadResources(device, queue, frames);
        EXPECT(resources.has_value());
        if (resources)
        {
            EXPECT(resources->buffer.valid());
            EXPECT(resources->buffer.size() == BUFFER_SOURCE.size());
            EXPECT(resources->texture.valid());
            EXPECT(resources->texture.format() == PixelFormat::rgba8_unorm);
            EXPECT(resources->texture.width() == TEXTURE_WIDTH);
            EXPECT(resources->texture.height() == TEXTURE_HEIGHT);
            EXPECT(resources->texture.mipLevels() == 1);
            EXPECT(resources->texture.usage() == MetalTextureUsage::shader_read);

            id<MTLBuffer> native_buffer =
                (__bridge id<MTLBuffer>)resources->buffer.nativeHandle();
            id<MTLTexture> native_texture =
                (__bridge id<MTLTexture>)resources->texture.nativeHandle();
            EXPECT(native_buffer != nil);
            EXPECT(native_texture != nil);
            EXPECT(native_buffer.storageMode == MTLStorageModePrivate);
            EXPECT(native_texture.storageMode == MTLStorageModePrivate);

            readbackResources(device, queue, frames, *resources);
            testInvalidArguments(device, queue, *resources);
            testReadbackBudgetAndOneShotFinish(device, queue, *resources);
        }

        testStagingExhaustionAndCancel(device, queue);
        testInvalidBatchDevice(device, queue);
        testLeaseBinding(device, queue);
    }

    if (gFailures != 0)
    {
        std::cerr << gFailures << " private resource transfer test(s) failed\n";
        return EXIT_FAILURE;
    }

    std::cout << "PASS Metal private resource transfers\n";
    return EXIT_SUCCESS;
}
