/**
 * @file texture-subresources-test-objc.mm
 * @brief Exact GPU tests for complete private texture subresource uploads.
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
#include "llmetalresource.h"
#include "llmetaltransfer.h"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

@interface FSTextureFailedCommandBuffer : NSObject

@property(nonatomic, copy, nullable) MTLCommandBufferHandler completionHandler;
@property(nonatomic) MTLCommandBufferStatus simulatedStatus;

- (void)addCompletedHandler:(MTLCommandBufferHandler)handler;
- (MTLCommandBufferStatus)status;
- (void)finishWithFailure;

@end

@implementation FSTextureFailedCommandBuffer

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

using firestorm::metal::MetalByteView;
using firestorm::metal::MetalCubeFace;
using firestorm::metal::MetalFrameContext;
using firestorm::metal::MetalPrivateTexture;
using firestorm::metal::MetalTextureDescriptor;
using firestorm::metal::MetalTextureKind;
using firestorm::metal::MetalTextureReadback;
using firestorm::metal::MetalTextureRegion;
using firestorm::metal::MetalTextureSubresourceUpload;
using firestorm::metal::MetalTextureUsage;
using firestorm::metal::MetalTransferBatch;
using firestorm::metal::MetalTransferStatus;
using firestorm::metal::PixelFormat;
using firestorm::metal::createPrivateTexture;
using firestorm::metal::kMaximumCubeArrayCount;
using firestorm::metal::kMaximumTextureDimension;

constexpr std::uint32_t kCubeCount   = 2;
constexpr std::uint32_t kSliceCount  = kCubeCount * 6U;
constexpr std::uint32_t kMipLevels   = 2;
constexpr std::uint32_t kBaseExtent  = 2;
constexpr std::uint32_t kAtlasWidth  = kSliceCount;
constexpr std::uint32_t kAtlasHeight = 5;
constexpr std::size_t kMip0Bytes     = 16;
constexpr std::size_t kMip1Bytes     = 4;
constexpr std::size_t kStagingBytes  =
    static_cast<std::size_t>(kSliceCount) * (512U + 256U);
constexpr std::size_t kAtlasReadbackBytes = 256U * kAtlasHeight;
constexpr std::size_t kMip0ReadbackBytes  = 256U * kBaseExtent;
constexpr std::size_t kMip1ReadbackBytes  = 256U;
constexpr std::size_t kReadbackBudget =
    kAtlasReadbackBytes + kMip0ReadbackBytes + kMip1ReadbackBytes;

std::size_t byteValue(std::byte value)
{
    return std::to_integer<std::size_t>(value);
}

MetalByteView byteView(const std::uint8_t* bytes, std::size_t size)
{
    return MetalByteView{ reinterpret_cast<const std::byte*>(bytes), size };
}

std::string commandError(id<MTLCommandBuffer> command_buffer)
{
    if (command_buffer == nil || command_buffer.error == nil)
    {
        return {};
    }

    const char* utf8 = command_buffer.error.localizedDescription.UTF8String;
    return utf8 == nullptr ? std::string{} : std::string(utf8);
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

MetalTextureDescriptor cubeArrayDescriptor()
{
    MetalTextureDescriptor descriptor;
    descriptor.kind       = MetalTextureKind::cube_array;
    descriptor.format     = PixelFormat::rgba8_unorm;
    descriptor.width      = kBaseExtent;
    descriptor.height     = kBaseExtent;
    descriptor.mipLevels  = kMipLevels;
    descriptor.arrayCount = kCubeCount;
    descriptor.usage      = MetalTextureUsage::shader_read;
    descriptor.label      = "Firestorm exact cube-array subresources";
    return descriptor;
}

struct TextureSources
{
    TextureSources()
    {
        for (std::uint32_t slice = 0; slice < kSliceCount; ++slice)
        {
            const std::uint8_t red = static_cast<std::uint8_t>(slice + 1U);
            mip0[slice] = {
                red, 0x10, 0x20, 0xff,
                red, 0x11, 0x20, 0xff,
                red, 0x10, 0x21, 0xff,
                red, 0x11, 0x21, 0xff,
            };
            mip1[slice] = { red, 0x12, 0x22, 0xff };
        }
    }

    std::vector<MetalTextureSubresourceUpload> uploads() const
    {
        std::vector<MetalTextureSubresourceUpload> result;
        result.reserve(static_cast<std::size_t>(kSliceCount) * kMipLevels);
        for (std::uint32_t index = kSliceCount; index != 0; --index)
        {
            const std::uint32_t slice = index - 1U;
            result.push_back(MetalTextureSubresourceUpload{
                1,
                slice,
                byteView(mip1[slice].data(), mip1[slice].size()),
                4,
            });
            result.push_back(MetalTextureSubresourceUpload{
                0,
                slice,
                byteView(mip0[slice].data(), mip0[slice].size()),
                8,
            });
        }
        return result;
    }

    std::array<std::array<std::uint8_t, kMip0Bytes>, kSliceCount> mip0{};
    std::array<std::array<std::uint8_t, kMip1Bytes>, kSliceCount> mip1{};
};

void testResourceDescriptors(id<MTLDevice> device)
{
    MetalPrivateTexture empty;
    EXPECT(!empty.valid());
    EXPECT(empty.kind() == MetalTextureKind::texture_2d);
    EXPECT(empty.arrayCount() == 0);
    EXPECT(empty.sliceCount() == 0);
    EXPECT(!empty.sliceForCubeFace(0, MetalCubeFace::positive_x).has_value());

    MetalTextureDescriptor descriptor = cubeArrayDescriptor();
    const auto cube_array = createPrivateTexture((__bridge void*)device, descriptor);
    EXPECT(cube_array.has_value());
    if (cube_array)
    {
        EXPECT(cube_array->valid());
        EXPECT(cube_array->kind() == MetalTextureKind::cube_array);
        EXPECT(cube_array->arrayCount() == kCubeCount);
        EXPECT(cube_array->sliceCount() == kSliceCount);
        EXPECT(cube_array->sliceForCubeFace(0, MetalCubeFace::positive_x) == 0);
        EXPECT(cube_array->sliceForCubeFace(0, MetalCubeFace::negative_x) == 1);
        EXPECT(cube_array->sliceForCubeFace(0, MetalCubeFace::positive_y) == 2);
        EXPECT(cube_array->sliceForCubeFace(0, MetalCubeFace::negative_y) == 3);
        EXPECT(cube_array->sliceForCubeFace(0, MetalCubeFace::positive_z) == 4);
        EXPECT(cube_array->sliceForCubeFace(0, MetalCubeFace::negative_z) == 5);
        EXPECT(cube_array->sliceForCubeFace(1, MetalCubeFace::positive_x) == 6);
        EXPECT(cube_array->sliceForCubeFace(1, MetalCubeFace::negative_z) == 11);
        EXPECT(!cube_array->sliceForCubeFace(2, MetalCubeFace::positive_x).has_value());
        EXPECT(!cube_array->sliceForCubeFace(
            0,
            static_cast<MetalCubeFace>(255)).has_value());

        id<MTLTexture> native =
            (__bridge id<MTLTexture>)cube_array->nativeHandle();
        EXPECT(native != nil);
        EXPECT(native.textureType == MTLTextureTypeCubeArray);
        EXPECT(native.arrayLength == kCubeCount);
        EXPECT(native.mipmapLevelCount == kMipLevels);
        EXPECT(native.storageMode == MTLStorageModePrivate);
    }

    descriptor.kind       = MetalTextureKind::cube;
    descriptor.arrayCount = 1;
    const auto cube = createPrivateTexture((__bridge void*)device, descriptor);
    EXPECT(cube.has_value());
    if (cube)
    {
        EXPECT(cube->kind() == MetalTextureKind::cube);
        EXPECT(cube->sliceCount() == 6);
        id<MTLTexture> native = (__bridge id<MTLTexture>)cube->nativeHandle();
        EXPECT(native.textureType == MTLTextureTypeCube);
        EXPECT(native.arrayLength == 1);
    }

    descriptor.kind       = MetalTextureKind::texture_2d;
    descriptor.width      = 4;
    descriptor.height     = 2;
    descriptor.arrayCount = 1;
    const auto texture_2d = createPrivateTexture((__bridge void*)device, descriptor);
    EXPECT(texture_2d.has_value());
    if (texture_2d)
    {
        EXPECT(texture_2d->kind() == MetalTextureKind::texture_2d);
        EXPECT(texture_2d->sliceCount() == 1);
        EXPECT(!texture_2d->sliceForCubeFace(0, MetalCubeFace::positive_x).has_value());
    }

    descriptor.width = kMaximumTextureDimension;
    descriptor.height = 1;
    EXPECT(createPrivateTexture((__bridge void*)device, descriptor).has_value());
    descriptor.width = kMaximumTextureDimension + 1U;
    EXPECT(!createPrivateTexture((__bridge void*)device, descriptor).has_value());

    MetalTextureDescriptor invalid = cubeArrayDescriptor();
    invalid.width = 3;
    EXPECT(!createPrivateTexture((__bridge void*)device, invalid).has_value());
    invalid = cubeArrayDescriptor();
    invalid.arrayCount = 0;
    EXPECT(!createPrivateTexture((__bridge void*)device, invalid).has_value());
    MetalTextureDescriptor maximum_cube_array = cubeArrayDescriptor();
    maximum_cube_array.arrayCount = kMaximumCubeArrayCount;
    EXPECT(createPrivateTexture((__bridge void*)device, maximum_cube_array).has_value());
    invalid = cubeArrayDescriptor();
    invalid.arrayCount = kMaximumCubeArrayCount + 1U;
    EXPECT(!createPrivateTexture((__bridge void*)device, invalid).has_value());
    invalid = cubeArrayDescriptor();
    invalid.mipLevels = 3;
    EXPECT(!createPrivateTexture((__bridge void*)device, invalid).has_value());
    invalid = cubeArrayDescriptor();
    invalid.kind = static_cast<MetalTextureKind>(255);
    EXPECT(!createPrivateTexture((__bridge void*)device, invalid).has_value());
    invalid = cubeArrayDescriptor();
    invalid.label.assign(1, static_cast<char>(0xff));
    EXPECT(!createPrivateTexture((__bridge void*)device, invalid).has_value());
    invalid = cubeArrayDescriptor();
    invalid.format = PixelFormat::depth32_float;
    invalid.usage = MetalTextureUsage::shader_write;
    EXPECT(!createPrivateTexture((__bridge void*)device, invalid).has_value());
    EXPECT(!createPrivateTexture(nullptr, cubeArrayDescriptor()).has_value());
}

void testUploadValidation(id<MTLDevice> device, id<MTLCommandQueue> queue)
{
    TextureSources sources;
    const auto valid_uploads = sources.uploads();
    MetalFrameContext frames((__bridge void*)device, kStagingBytes);
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
                             0);
    std::atomic<unsigned> publications{ 0 };
    auto publish = [&](std::uint64_t, MetalPrivateTexture) { ++publications; };

    auto missing = valid_uploads;
    missing.pop_back();
    EXPECT(batch.uploadPrivateTexture(cubeArrayDescriptor(), missing, publish) ==
           MetalTransferStatus::invalid_argument);

    auto duplicate = valid_uploads;
    duplicate.back() = duplicate.front();
    EXPECT(batch.uploadPrivateTexture(cubeArrayDescriptor(), duplicate, publish) ==
           MetalTransferStatus::invalid_argument);

    auto bad_slice = valid_uploads;
    bad_slice.front().slice = kSliceCount;
    EXPECT(batch.uploadPrivateTexture(cubeArrayDescriptor(), bad_slice, publish) ==
           MetalTransferStatus::invalid_argument);

    auto bad_mip = valid_uploads;
    bad_mip.front().mipLevel = kMipLevels;
    EXPECT(batch.uploadPrivateTexture(cubeArrayDescriptor(), bad_mip, publish) ==
           MetalTransferStatus::invalid_argument);

    auto bad_row = valid_uploads;
    bad_row.front().bytesPerRow = 3;
    EXPECT(batch.uploadPrivateTexture(cubeArrayDescriptor(), bad_row, publish) ==
           MetalTransferStatus::invalid_argument);

    MetalTextureDescriptor too_many_cubes = cubeArrayDescriptor();
    too_many_cubes.width = 1;
    too_many_cubes.height = 1;
    too_many_cubes.mipLevels = 1;
    too_many_cubes.arrayCount = kMaximumCubeArrayCount + 1U;
    std::array<std::uint8_t, 4> one_pixel{ 0, 0, 0, 0xff };
    std::vector<MetalTextureSubresourceUpload> too_many_subresources;
    too_many_subresources.reserve(
        static_cast<std::size_t>(too_many_cubes.arrayCount) * 6U);
    for (std::uint32_t slice = 0; slice < too_many_cubes.arrayCount * 6U; ++slice)
    {
        too_many_subresources.push_back(MetalTextureSubresourceUpload{
            0,
            slice,
            byteView(one_pixel.data(), one_pixel.size()),
            4,
        });
    }
    EXPECT(batch.uploadPrivateTexture(
               too_many_cubes, too_many_subresources, publish) ==
           MetalTransferStatus::invalid_argument);

    MetalTextureDescriptor too_wide = cubeArrayDescriptor();
    too_wide.kind = MetalTextureKind::texture_2d;
    too_wide.width = kMaximumTextureDimension + 1U;
    too_wide.height = 1;
    too_wide.mipLevels = 1;
    too_wide.arrayCount = 1;
    std::vector<std::uint8_t> oversized_row(
        static_cast<std::size_t>(too_wide.width) * 4U);
    std::vector<MetalTextureSubresourceUpload> too_wide_subresources{
        MetalTextureSubresourceUpload{
            0,
            0,
            byteView(oversized_row.data(), oversized_row.size()),
            oversized_row.size(),
        },
    };
    EXPECT(batch.uploadPrivateTexture(
               too_wide, too_wide_subresources, publish) ==
           MetalTransferStatus::invalid_argument);

    EXPECT(batch.uploadPrivateTexture(cubeArrayDescriptor(), valid_uploads, {}) ==
           MetalTransferStatus::invalid_argument);
    EXPECT(batch.uploadPrivateTexture(cubeArrayDescriptor(), valid_uploads, publish) ==
           MetalTransferStatus::encoded);
    EXPECT(publications.load(std::memory_order_relaxed) == 0);
    batch.cancel();
    EXPECT(!frames.cancel(lease->token));

    MetalFrameContext too_small((__bridge void*)device, kStagingBytes - 1U);
    const auto small_lease = too_small.tryBegin();
    EXPECT(small_lease.has_value());
    if (!small_lease)
    {
        return;
    }
    id<MTLCommandBuffer> small_command = [queue commandBuffer];
    EXPECT(small_command != nil);
    if (small_command == nil)
    {
        EXPECT(too_small.cancel(small_lease->token));
        return;
    }
    MetalTransferBatch small_batch((__bridge void*)device,
                                   too_small,
                                   *small_lease,
                                   (__bridge void*)small_command,
                                   0);
    EXPECT(small_batch.uploadPrivateTexture(
               cubeArrayDescriptor(), valid_uploads, publish) ==
           MetalTransferStatus::staging_full);
    EXPECT(publications.load(std::memory_order_relaxed) == 0);
    small_batch.cancel();
    EXPECT(!too_small.cancel(small_lease->token));
}

std::optional<MetalPrivateTexture>
uploadCubeArray(id<MTLDevice> device,
                id<MTLCommandQueue> queue,
                MetalFrameContext& frames,
                TextureSources& sources)
{
    const auto lease = frames.tryBegin();
    EXPECT(lease.has_value());
    if (!lease)
    {
        return std::nullopt;
    }

    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    id<MTLSharedEvent> gate = [device newSharedEvent];
    EXPECT(command_buffer != nil);
    EXPECT(gate != nil);
    if (command_buffer == nil || gate == nil)
    {
        EXPECT(frames.cancel(lease->token));
        return std::nullopt;
    }
    [command_buffer encodeWaitForEvent:gate value:1];

    std::mutex mutex;
    std::optional<MetalPrivateTexture> publication;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             0);
    auto uploads = sources.uploads();
    EXPECT(batch.uploadPrivateTexture(
               cubeArrayDescriptor(),
               uploads,
               [&](std::uint64_t, MetalPrivateTexture texture) {
                   {
                       std::lock_guard<std::mutex> lock(mutex);
                       publication = std::move(texture);
                   }
                   dispatch_semaphore_signal(done);
               }) == MetalTransferStatus::encoded);
    for (auto& mip : sources.mip0)
    {
        mip.fill(0);
    }
    for (auto& mip : sources.mip1)
    {
        mip.fill(0);
    }
    uploads.clear();

    auto completion = batch.finish();
    EXPECT(completion.has_value());
    if (!completion)
    {
        EXPECT(frames.cancel(lease->token));
        return std::nullopt;
    }
    const auto serial = frames.submit(lease->token,
                                      (__bridge void*)command_buffer,
                                      std::move(*completion));
    EXPECT(serial.has_value());
    if (!serial)
    {
        EXPECT(frames.cancel(lease->token));
        return std::nullopt;
    }

    [command_buffer commit];
    EXPECT(dispatch_semaphore_wait(done, DISPATCH_TIME_NOW) != 0);
    gate.signaledValue = 1;
    requireSignal(done, command_buffer, "complete cube-array upload");
    EXPECT(command_buffer.status == MTLCommandBufferStatusCompleted);

    std::lock_guard<std::mutex> lock(mutex);
    EXPECT(publication.has_value());
    return publication;
}

struct ReadbackPublications
{
    std::mutex mutex;
    std::optional<MetalTextureReadback> atlas;
    std::optional<MetalTextureReadback> slice11Mip0;
    std::optional<MetalTextureReadback> slice2Mip1;
    std::vector<std::string> order;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
};

void recordAtlasCopies(id<MTLBlitCommandEncoder> encoder,
                       id<MTLTexture> source,
                       id<MTLTexture> atlas)
{
    constexpr std::array<MTLOrigin, 4> origins{
        MTLOrigin{ 0, 0, 0 },
        MTLOrigin{ 1, 0, 0 },
        MTLOrigin{ 0, 1, 0 },
        MTLOrigin{ 1, 1, 0 },
    };
    for (std::uint32_t slice = 0; slice < kSliceCount; ++slice)
    {
        for (std::size_t row = 0; row < origins.size(); ++row)
        {
            [encoder copyFromTexture:source
                         sourceSlice:slice
                         sourceLevel:0
                        sourceOrigin:origins[row]
                          sourceSize:MTLSizeMake(1, 1, 1)
                           toTexture:atlas
                    destinationSlice:0
                    destinationLevel:0
                   destinationOrigin:MTLOriginMake(slice, row, 0)];
        }
        [encoder copyFromTexture:source
                     sourceSlice:slice
                     sourceLevel:1
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(1, 1, 1)
                       toTexture:atlas
                destinationSlice:0
                destinationLevel:0
               destinationOrigin:MTLOriginMake(slice, 4, 0)];
    }
}

void validatePixel(const MetalTextureReadback& readback,
                   std::uint32_t x,
                   std::uint32_t y,
                   const std::array<std::uint8_t, 4>& expected,
                   const char* label)
{
    const std::size_t offset =
        static_cast<std::size_t>(y) * readback.bytesPerRow +
        static_cast<std::size_t>(x) * 4U;
    if (offset > readback.bytes.size() ||
        readback.bytes.size() - offset < expected.size())
    {
        std::cerr << "FAIL " << label << " missing pixel (" << x << ',' << y << ")\n";
        ++gFailures;
        return;
    }
    for (std::size_t channel = 0; channel < expected.size(); ++channel)
    {
        if (byteValue(readback.bytes[offset + channel]) != expected[channel])
        {
            std::cerr << "FAIL " << label << " pixel=(" << x << ',' << y
                      << ") channel=" << channel
                      << " expected=" << static_cast<unsigned>(expected[channel])
                      << " actual=" << byteValue(readback.bytes[offset + channel])
                      << " bytes_per_row=" << readback.bytesPerRow << '\n';
            ++gFailures;
            return;
        }
    }
}

void validateAtlas(const MetalTextureReadback& readback)
{
    EXPECT(readback.format == PixelFormat::rgba8_unorm);
    EXPECT(readback.region.x == 0);
    EXPECT(readback.region.y == 0);
    EXPECT(readback.region.width == kAtlasWidth);
    EXPECT(readback.region.height == kAtlasHeight);
    EXPECT(readback.region.slice == 0);
    EXPECT(readback.region.mipLevel == 0);
    EXPECT(readback.bytesPerRow == 256);
    EXPECT(readback.bytesPerImage == kAtlasReadbackBytes);
    EXPECT(readback.bytes.size() == kAtlasReadbackBytes);

    constexpr std::array<std::uint8_t, 4> greens{ 0x10, 0x11, 0x10, 0x11 };
    constexpr std::array<std::uint8_t, 4> blues{ 0x20, 0x20, 0x21, 0x21 };
    for (std::uint32_t slice = 0; slice < kSliceCount; ++slice)
    {
        const std::uint8_t red = static_cast<std::uint8_t>(slice + 1U);
        for (std::uint32_t row = 0; row < 4; ++row)
        {
            validatePixel(readback,
                          slice,
                          row,
                          { red, greens[row], blues[row], 0xff },
                          "12x5 cube-array atlas");
        }
        validatePixel(readback,
                      slice,
                      4,
                      { red, 0x12, 0x22, 0xff },
                      "12x5 cube-array atlas mip1");
    }
}

void validateDirectReadbacks(const ReadbackPublications& publications)
{
    EXPECT(publications.slice11Mip0.has_value());
    if (publications.slice11Mip0)
    {
        const MetalTextureReadback& readback = *publications.slice11Mip0;
        EXPECT(readback.region.slice == 11);
        EXPECT(readback.region.mipLevel == 0);
        EXPECT(readback.region.width == 2);
        EXPECT(readback.region.height == 2);
        EXPECT(readback.bytesPerRow == 256);
        EXPECT(readback.bytesPerImage == kMip0ReadbackBytes);
        validatePixel(readback, 0, 0, { 12, 0x10, 0x20, 0xff }, "slice11 mip0");
        validatePixel(readback, 1, 0, { 12, 0x11, 0x20, 0xff }, "slice11 mip0");
        validatePixel(readback, 0, 1, { 12, 0x10, 0x21, 0xff }, "slice11 mip0");
        validatePixel(readback, 1, 1, { 12, 0x11, 0x21, 0xff }, "slice11 mip0");
    }

    EXPECT(publications.slice2Mip1.has_value());
    if (publications.slice2Mip1)
    {
        const MetalTextureReadback& readback = *publications.slice2Mip1;
        EXPECT(readback.region.slice == 2);
        EXPECT(readback.region.mipLevel == 1);
        EXPECT(readback.region.width == 1);
        EXPECT(readback.region.height == 1);
        EXPECT(readback.bytesPerRow == 256);
        EXPECT(readback.bytesPerImage == kMip1ReadbackBytes);
        validatePixel(readback, 0, 0, { 3, 0x12, 0x22, 0xff }, "slice2 mip1");
    }
}

void readbackExactAtlas(id<MTLDevice> device,
                        id<MTLCommandQueue> queue,
                        const MetalPrivateTexture& cube_array)
{
    MetalTextureDescriptor atlas_descriptor;
    atlas_descriptor.kind       = MetalTextureKind::texture_2d;
    atlas_descriptor.format     = PixelFormat::rgba8_unorm;
    atlas_descriptor.width      = kAtlasWidth;
    atlas_descriptor.height     = kAtlasHeight;
    atlas_descriptor.mipLevels  = 1;
    atlas_descriptor.arrayCount = 1;
    atlas_descriptor.usage      = MetalTextureUsage::shader_read;
    atlas_descriptor.label      = "Firestorm exact cube-array atlas";
    const auto atlas = createPrivateTexture((__bridge void*)device, atlas_descriptor);
    EXPECT(atlas.has_value());
    if (!atlas)
    {
        return;
    }

    MetalFrameContext frames((__bridge void*)device, 256);
    const auto lease = frames.tryBegin();
    EXPECT(lease.has_value());
    if (!lease)
    {
        return;
    }
    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    id<MTLBlitCommandEncoder> atlas_encoder = [command_buffer blitCommandEncoder];
    EXPECT(command_buffer != nil);
    EXPECT(atlas_encoder != nil);
    if (command_buffer == nil || atlas_encoder == nil)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }
    recordAtlasCopies(atlas_encoder,
                      (__bridge id<MTLTexture>)cube_array.nativeHandle(),
                      (__bridge id<MTLTexture>)atlas->nativeHandle());
    [atlas_encoder endEncoding];

    ReadbackPublications publications;
    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             kReadbackBudget);
    auto publish = [&](std::string name,
                       std::optional<MetalTextureReadback> ReadbackPublications::*slot) {
        return [&, name = std::move(name), slot](
                   std::uint64_t, MetalTextureReadback readback) mutable {
            bool complete = false;
            {
                std::lock_guard<std::mutex> lock(publications.mutex);
                publications.*slot = std::move(readback);
                publications.order.push_back(std::move(name));
                complete = publications.order.size() == 3;
            }
            if (complete)
            {
                dispatch_semaphore_signal(publications.done);
            }
        };
    };

    EXPECT(batch.readbackTexture(
               *atlas,
               MetalTextureRegion{ 0, 0, kAtlasWidth, kAtlasHeight, 0, 0 },
               publish("atlas", &ReadbackPublications::atlas)) ==
           MetalTransferStatus::encoded);
    EXPECT(batch.readbackTexture(
               cube_array,
               MetalTextureRegion{ 0, 0, 2, 2, 0, 11 },
               publish("slice11", &ReadbackPublications::slice11Mip0)) ==
           MetalTransferStatus::encoded);
    EXPECT(batch.readbackTexture(
               cube_array,
               MetalTextureRegion{ 0, 0, 1, 1, 1, 2 },
               publish("slice2mip1", &ReadbackPublications::slice2Mip1)) ==
           MetalTransferStatus::encoded);
    EXPECT(batch.readbackTexture(
               cube_array,
               MetalTextureRegion{ 0, 0, 1, 1, 0, kSliceCount },
               publish("invalid-slice", &ReadbackPublications::slice2Mip1)) ==
           MetalTransferStatus::invalid_argument);
    EXPECT(batch.readbackTexture(
               cube_array,
               MetalTextureRegion{ 0, 0, 1, 1, kMipLevels, 0 },
               publish("invalid-mip", &ReadbackPublications::slice2Mip1)) ==
           MetalTransferStatus::invalid_argument);
    EXPECT(batch.readbackTexture(
               cube_array,
               MetalTextureRegion{ 0, 0, 1, 1, 1, 2 },
               publish("over-budget", &ReadbackPublications::slice2Mip1)) ==
           MetalTransferStatus::readback_budget_exceeded);
    auto completion = batch.finish();
    EXPECT(completion.has_value());
    if (!completion)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }
    const auto serial = frames.submit(lease->token,
                                      (__bridge void*)command_buffer,
                                      std::move(*completion));
    EXPECT(serial.has_value());
    if (!serial)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }
    [command_buffer commit];
    requireSignal(publications.done, command_buffer, "cube-array atlas readbacks");
    EXPECT(command_buffer.status == MTLCommandBufferStatusCompleted);

    std::lock_guard<std::mutex> lock(publications.mutex);
    EXPECT(publications.order ==
           std::vector<std::string>({ "atlas", "slice11", "slice2mip1" }));
    EXPECT(publications.atlas.has_value());
    if (publications.atlas)
    {
        validateAtlas(*publications.atlas);
    }
    validateDirectReadbacks(publications);
}

struct OrderedPublications
{
    std::mutex mutex;
    std::vector<char> order;
    std::vector<std::uint64_t> serials;
    dispatch_semaphore_t firstDone  = dispatch_semaphore_create(0);
    dispatch_semaphore_t secondDone = dispatch_semaphore_create(0);
};

struct PendingUpload
{
    id<MTLCommandBuffer> commandBuffer = nil;
    id<MTLSharedEvent> gate = nil;
    std::uint64_t serial = 0;
};

std::optional<PendingUpload>
recordPendingUpload(id<MTLDevice> device,
                    id<MTLCommandQueue> queue,
                    MetalFrameContext& frames,
                    std::uint8_t value,
                    char name,
                    OrderedPublications& publications)
{
    const auto lease = frames.tryBegin();
    if (!lease)
    {
        return std::nullopt;
    }
    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    id<MTLSharedEvent> gate = [device newSharedEvent];
    if (command_buffer == nil || gate == nil)
    {
        EXPECT(frames.cancel(lease->token));
        return std::nullopt;
    }
    [command_buffer encodeWaitForEvent:gate value:1];

    MetalTextureDescriptor descriptor;
    descriptor.width = 1;
    descriptor.height = 1;
    descriptor.usage = MetalTextureUsage::shader_read;
    descriptor.label = "Firestorm ordered texture publication";
    const std::array<std::uint8_t, 4> pixel{ value, 0, 0, 0xff };
    const std::vector<MetalTextureSubresourceUpload> upload{
        MetalTextureSubresourceUpload{ 0, 0, byteView(pixel.data(), pixel.size()), 4 },
    };

    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             0);
    if (batch.uploadPrivateTexture(
            descriptor,
            upload,
            [&, name](std::uint64_t serial, MetalPrivateTexture) {
                {
                    std::lock_guard<std::mutex> lock(publications.mutex);
                    publications.order.push_back(name);
                    publications.serials.push_back(serial);
                }
                dispatch_semaphore_signal(name == 'A'
                                              ? publications.firstDone
                                              : publications.secondDone);
            }) != MetalTransferStatus::encoded)
    {
        batch.cancel();
        return std::nullopt;
    }
    auto completion = batch.finish();
    if (!completion)
    {
        EXPECT(frames.cancel(lease->token));
        return std::nullopt;
    }
    const auto serial = frames.submit(lease->token,
                                      (__bridge void*)command_buffer,
                                      std::move(*completion));
    if (!serial)
    {
        EXPECT(frames.cancel(lease->token));
        return std::nullopt;
    }
    [command_buffer commit];
    return PendingUpload{ command_buffer, gate, *serial };
}

void testOutOfOrderPublication(id<MTLDevice> device, id<MTLCommandQueue> queue)
{
    MetalFrameContext frames((__bridge void*)device, 256);
    OrderedPublications publications;
    id<MTLCommandQueue> second_queue = [device newCommandQueue];
    EXPECT(second_queue != nil);
    if (second_queue == nil)
    {
        return;
    }
    const auto first = recordPendingUpload(device, queue, frames, 1, 'A', publications);
    const auto second = recordPendingUpload(device,
                                            second_queue,
                                            frames,
                                            2,
                                            'B',
                                            publications);
    EXPECT(first.has_value());
    EXPECT(second.has_value());
    if (!first || !second)
    {
        if (first)
        {
            first->gate.signaledValue = 1;
            requireSignal(publications.firstDone,
                          first->commandBuffer,
                          "cleanup first texture publication");
        }
        if (second)
        {
            second->gate.signaledValue = 1;
            requireSignal(publications.secondDone,
                          second->commandBuffer,
                          "cleanup second texture publication");
        }
        return;
    }
    EXPECT(second->serial > first->serial);

    second->gate.signaledValue = 1;
    requireSignal(publications.secondDone,
                  second->commandBuffer,
                  "newer texture publication");
    {
        std::lock_guard<std::mutex> lock(publications.mutex);
        EXPECT(publications.order == std::vector<char>({ 'B' }));
        EXPECT(publications.serials ==
               std::vector<std::uint64_t>({ second->serial }));
    }

    first->gate.signaledValue = 1;
    requireSignal(publications.firstDone,
                  first->commandBuffer,
                  "older texture publication");
    std::lock_guard<std::mutex> lock(publications.mutex);
    EXPECT(publications.order == std::vector<char>({ 'B', 'A' }));
    EXPECT(publications.serials ==
           std::vector<std::uint64_t>({ second->serial, first->serial }));
}

void testFailedCommandDoesNotPublish(id<MTLDevice> device,
                                     id<MTLCommandQueue> queue)
{
    MetalFrameContext frames((__bridge void*)device, 256);
    const auto lease = frames.tryBegin();
    EXPECT(lease.has_value());
    if (!lease)
    {
        return;
    }
    id<MTLCommandBuffer> real_command = [queue commandBuffer];
    EXPECT(real_command != nil);
    if (real_command == nil)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    MetalTextureDescriptor descriptor;
    descriptor.width = 1;
    descriptor.height = 1;
    descriptor.usage = MetalTextureUsage::shader_read;
    const std::array<std::uint8_t, 4> pixel{ 1, 2, 3, 4 };
    const std::vector<MetalTextureSubresourceUpload> upload{
        MetalTextureSubresourceUpload{ 0, 0, byteView(pixel.data(), pixel.size()), 4 },
    };
    std::atomic<bool> published{ false };
    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)real_command,
                             0);
    EXPECT(batch.uploadPrivateTexture(
               descriptor,
               upload,
               [&](std::uint64_t, MetalPrivateTexture) {
                   published.store(true, std::memory_order_relaxed);
               }) == MetalTransferStatus::encoded);
    auto completion = batch.finish();
    EXPECT(completion.has_value());
    if (!completion)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    FSTextureFailedCommandBuffer* failed =
        [[FSTextureFailedCommandBuffer alloc] init];
    failed.simulatedStatus = MTLCommandBufferStatusNotEnqueued;
    const auto serial = frames.submit(lease->token,
                                      (__bridge void*)failed,
                                      std::move(*completion));
    EXPECT(serial.has_value());
    if (!serial)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }
    [failed finishWithFailure];
    EXPECT(!published.load(std::memory_order_relaxed));
    EXPECT(!frames.cancel(lease->token));
    const auto reused = frames.tryBegin();
    EXPECT(reused.has_value());
    if (reused)
    {
        EXPECT(frames.cancel(reused->token));
    }
}

void testStrongWrapperLifetime(MetalPrivateTexture texture)
{
    EXPECT(texture.valid());
    MetalPrivateTexture copy = texture;
    const auto native = texture.nativeHandle();
    texture = {};
    EXPECT(copy.valid());
    EXPECT(copy.nativeHandle() == native);
    EXPECT(copy.sliceCount() == kSliceCount);
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

        testResourceDescriptors(device);
        testUploadValidation(device, queue);

        TextureSources sources;
        MetalFrameContext upload_frames((__bridge void*)device, kStagingBytes);
        EXPECT(upload_frames.valid());
        const auto cube_array = uploadCubeArray(device, queue, upload_frames, sources);
        EXPECT(cube_array.has_value());
        if (cube_array)
        {
            EXPECT(cube_array->valid());
            EXPECT(cube_array->kind() == MetalTextureKind::cube_array);
            EXPECT(cube_array->sliceCount() == kSliceCount);
            testStrongWrapperLifetime(*cube_array);
            readbackExactAtlas(device, queue, *cube_array);
        }

        testOutOfOrderPublication(device, queue);
        testFailedCommandDoesNotPublish(device, queue);
    }

    if (gFailures != 0)
    {
        std::cerr << gFailures << " texture subresource test(s) failed\n";
        return EXIT_FAILURE;
    }

    std::cout << "PASS Metal complete texture subresources\n";
    return EXIT_SUCCESS;
}
