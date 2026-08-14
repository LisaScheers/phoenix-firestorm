/**
 * @file sampler-test-objc.mm
 * @brief Deterministic sampler-cache and private-texture GPU validation.
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
#include "llmetalsampler.h"
#include "llmetaltransfer.h"

#include <array>
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

using firestorm::metal::MetalFrameContext;
using firestorm::metal::MetalPrivateTexture2D;
using firestorm::metal::MetalSamplerCache;
using firestorm::metal::MetalSamplerHandle;
using firestorm::metal::MetalTexture2DDescriptor;
using firestorm::metal::MetalTextureReadback;
using firestorm::metal::MetalTextureRegion;
using firestorm::metal::MetalTextureUpload2D;
using firestorm::metal::MetalTextureUsage;
using firestorm::metal::MetalTransferBatch;
using firestorm::metal::MetalTransferStatus;
using firestorm::metal::PixelFormat;
using firestorm::metal::SamplerAddressMode;
using firestorm::metal::SamplerDesc;
using firestorm::metal::SamplerFilter;
using firestorm::metal::SamplerKeyHash;
using firestorm::metal::SamplerMipFilter;
using firestorm::metal::createPrivateTexture2D;
using firestorm::metal::makeSamplerKey;

constexpr std::uint32_t WIDTH  = 2;
constexpr std::uint32_t HEIGHT = 1;
constexpr std::size_t   ACTIVE_ROW_BYTES = 8;

constexpr std::array<std::uint8_t, ACTIVE_ROW_BYTES> SOURCE_PIXELS{
    255, 0, 0, 255,
    0, 255, 0, 255,
};

// Sampling u=-0.125 wraps to the green texel and clamps to the red texel.
constexpr std::array<std::uint8_t, ACTIVE_ROW_BYTES> EXPECTED_PIXELS{
    0, 255, 0, 255,
    255, 0, 0, 255,
};

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

bool parseOptions(int argc, const char* argv[], std::string& metallib_path)
{
    if (argc == 3 && std::string(argv[1]) == "--metallib")
    {
        metallib_path = argv[2];
        return !metallib_path.empty();
    }

    std::cerr << "Usage: " << argv[0] << " --metallib PATH\n";
    return false;
}

id<MTLLibrary> loadLibrary(id<MTLDevice> device, const std::string& path)
{
    NSString* native_path = [[NSString alloc] initWithBytes:path.data()
                                                      length:path.size()
                                                    encoding:NSUTF8StringEncoding];
    EXPECT(native_path != nil);
    if (native_path == nil)
    {
        return nil;
    }

    NSError* error = nil;
    id<MTLLibrary> library = [device
        newLibraryWithURL:[NSURL fileURLWithPath:native_path]
        error:&error];
    if (library == nil)
    {
        std::cerr << "FAIL load sampler metallib: "
                  << toString(error.localizedDescription) << '\n';
        ++gFailures;
    }
    return library;
}

void testKeyContract()
{
    SamplerDesc descriptor;
    descriptor.s = SamplerAddressMode::repeat;
    descriptor.t = SamplerAddressMode::mirror_repeat;
    descriptor.r = SamplerAddressMode::clamp_to_edge;
    descriptor.min = SamplerFilter::linear;
    descriptor.mag = SamplerFilter::nearest;
    descriptor.mip = SamplerMipFilter::nearest;
    descriptor.maxAnisotropy = 4;

    const auto one_level = makeSamplerKey(descriptor, 1);
    EXPECT(one_level.has_value());
    if (one_level)
    {
        EXPECT(one_level->mip == SamplerMipFilter::not_mipmapped);
        EXPECT(one_level->s == descriptor.s);
        EXPECT(one_level->t == descriptor.t);
        EXPECT(one_level->r == descriptor.r);
        EXPECT(one_level->min == descriptor.min);
        EXPECT(one_level->mag == descriptor.mag);
        EXPECT(one_level->maxAnisotropy == descriptor.maxAnisotropy);
    }

    const auto several_levels = makeSamplerKey(descriptor, 3);
    EXPECT(several_levels.has_value());
    if (several_levels)
    {
        EXPECT(several_levels->mip == SamplerMipFilter::nearest);
    }

    SamplerDesc equivalent = descriptor;
    equivalent.mip = SamplerMipFilter::linear;
    const auto equivalent_one_level = makeSamplerKey(equivalent, 1);
    EXPECT(equivalent_one_level == one_level);
    if (one_level && equivalent_one_level)
    {
        EXPECT(SamplerKeyHash{}(*one_level) ==
               SamplerKeyHash{}(*equivalent_one_level));
    }

    EXPECT(!makeSamplerKey(descriptor, 0).has_value());

    SamplerDesc invalid = descriptor;
    invalid.s = static_cast<SamplerAddressMode>(255);
    EXPECT(!makeSamplerKey(invalid, 1).has_value());
    invalid = descriptor;
    invalid.t = static_cast<SamplerAddressMode>(255);
    EXPECT(!makeSamplerKey(invalid, 1).has_value());
    invalid = descriptor;
    invalid.r = static_cast<SamplerAddressMode>(255);
    EXPECT(!makeSamplerKey(invalid, 1).has_value());
    invalid = descriptor;
    invalid.min = static_cast<SamplerFilter>(255);
    EXPECT(!makeSamplerKey(invalid, 1).has_value());
    invalid = descriptor;
    invalid.mag = static_cast<SamplerFilter>(255);
    EXPECT(!makeSamplerKey(invalid, 1).has_value());
    invalid = descriptor;
    invalid.mip = static_cast<SamplerMipFilter>(255);
    EXPECT(!makeSamplerKey(invalid, 1).has_value());
    invalid = descriptor;
    invalid.maxAnisotropy = 0;
    EXPECT(!makeSamplerKey(invalid, 1).has_value());
    invalid.maxAnisotropy = 17;
    EXPECT(!makeSamplerKey(invalid, 1).has_value());
}

std::optional<MetalPrivateTexture2D>
uploadSourceTexture(id<MTLDevice> device,
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
    command_buffer.label = @"Firestorm sampler source upload";

    std::mutex publication_mutex;
    std::optional<MetalPrivateTexture2D> published_texture;
    dispatch_semaphore_t published = dispatch_semaphore_create(0);

    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             0);
    EXPECT(batch.valid());

    MetalTexture2DDescriptor descriptor;
    descriptor.format    = PixelFormat::rgba8_unorm;
    descriptor.width     = WIDTH;
    descriptor.height    = HEIGHT;
    descriptor.mipLevels = 1;
    descriptor.usage     = MetalTextureUsage::shader_read;
    descriptor.label     = "Firestorm sampler 2x1 private source";

    const MetalTextureUpload2D upload{
        { reinterpret_cast<const std::byte*>(SOURCE_PIXELS.data()),
          SOURCE_PIXELS.size() },
        ACTIVE_ROW_BYTES,
    };
    EXPECT(batch.uploadPrivateTexture2D(
               descriptor,
               upload,
               [&](std::uint64_t, MetalPrivateTexture2D texture) {
                   {
                       std::lock_guard<std::mutex> lock(publication_mutex);
                       published_texture = std::move(texture);
                   }
                   dispatch_semaphore_signal(published);
               }) == MetalTransferStatus::encoded);

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
    requireSignal(published, command_buffer, "private sampler source upload");
    EXPECT(command_buffer.status == MTLCommandBufferStatusCompleted);
    EXPECT(command_buffer.error == nil);

    std::lock_guard<std::mutex> lock(publication_mutex);
    return published_texture;
}

struct CachedSamplers
{
    MetalSamplerHandle repeat = nullptr;
    MetalSamplerHandle clamp  = nullptr;
};

void testInvalidCacheDevices()
{
    MetalSamplerCache null_cache(nullptr);
    EXPECT(!null_cache.valid());
    EXPECT(!null_cache.sampler(SamplerDesc{}, 1).has_value());
    EXPECT(null_cache.hitCount() == 0);
    EXPECT(null_cache.missCount() == 0);
    EXPECT(null_cache.entryCount() == 0);

    NSObject* not_a_device = [[NSObject alloc] init];
    MetalSamplerCache wrong_type((__bridge void*)not_a_device);
    EXPECT(!wrong_type.valid());
}

void runSamplerGpuTest(id<MTLDevice> device,
                       id<MTLCommandQueue> queue,
                       id<MTLComputePipelineState> pipeline,
                       MetalFrameContext& frames,
                       const MetalPrivateTexture2D& source,
                       const CachedSamplers& samplers)
{
    MetalTexture2DDescriptor output_descriptor;
    output_descriptor.format    = PixelFormat::rgba8_unorm;
    output_descriptor.width     = WIDTH;
    output_descriptor.height    = HEIGHT;
    output_descriptor.mipLevels = 1;
    output_descriptor.usage     = MetalTextureUsage::shader_write;
    output_descriptor.label     = "Firestorm sampler 2x1 private output";
    const auto output = createPrivateTexture2D((__bridge void*)device,
                                                output_descriptor);
    EXPECT(output.has_value());
    if (!output)
    {
        return;
    }

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
    command_buffer.label = @"Firestorm sampler exact GPU validation";

    id<MTLComputeCommandEncoder> encoder = [command_buffer computeCommandEncoder];
    EXPECT(encoder != nil);
    if (encoder == nil)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }
    encoder.label = @"Firestorm repeat and clamp sampler encoder";
    [encoder setComputePipelineState:pipeline];
    [encoder setTexture:(__bridge id<MTLTexture>)source.nativeHandle() atIndex:0];
    [encoder setTexture:(__bridge id<MTLTexture>)output->nativeHandle() atIndex:1];
    [encoder setSamplerState:(__bridge id<MTLSamplerState>)samplers.repeat atIndex:0];
    [encoder setSamplerState:(__bridge id<MTLSamplerState>)samplers.clamp atIndex:1];
    [encoder dispatchThreads:MTLSizeMake(WIDTH, HEIGHT, 1)
        threadsPerThreadgroup:MTLSizeMake(WIDTH, HEIGHT, 1)];
    [encoder endEncoding];

    std::mutex publication_mutex;
    std::optional<MetalTextureReadback> publication;
    dispatch_semaphore_t published = dispatch_semaphore_create(0);

    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             256);
    EXPECT(batch.valid());
    const MetalTextureRegion region{ 0, 0, WIDTH, HEIGHT, 0, 0 };
    EXPECT(batch.readbackTexture2D(
               *output,
               region,
               [&](std::uint64_t, MetalTextureReadback readback) {
                   {
                       std::lock_guard<std::mutex> lock(publication_mutex);
                       publication = std::move(readback);
                   }
                   dispatch_semaphore_signal(published);
               }) == MetalTransferStatus::encoded);

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
    requireSignal(published, command_buffer, "sampler output readback");
    EXPECT(command_buffer.status == MTLCommandBufferStatusCompleted);
    EXPECT(command_buffer.error == nil);

    std::lock_guard<std::mutex> lock(publication_mutex);
    EXPECT(publication.has_value());
    if (!publication)
    {
        return;
    }
    EXPECT(publication->format == PixelFormat::rgba8_unorm);
    EXPECT(publication->region.x == 0);
    EXPECT(publication->region.y == 0);
    EXPECT(publication->region.width == WIDTH);
    EXPECT(publication->region.height == HEIGHT);
    EXPECT(publication->bytesPerRow >= ACTIVE_ROW_BYTES);
    EXPECT(publication->bytes.size() >= publication->bytesPerRow);
    if (publication->bytesPerRow < ACTIVE_ROW_BYTES ||
        publication->bytes.size() < publication->bytesPerRow)
    {
        return;
    }

    for (std::size_t offset = 0; offset < ACTIVE_ROW_BYTES; ++offset)
    {
        const std::uint8_t actual =
            std::to_integer<std::uint8_t>(publication->bytes[offset]);
        if (actual != EXPECTED_PIXELS[offset])
        {
            std::cerr << "FAIL sampler pixel=" << offset / 4
                      << " channel=" << offset % 4
                      << " expected="
                      << static_cast<unsigned>(EXPECTED_PIXELS[offset])
                      << " actual=" << static_cast<unsigned>(actual) << '\n';
            ++gFailures;
        }
    }
}

} // namespace

int main(int argc, const char* argv[])
{
    std::string metallib_path;
    if (!parseOptions(argc, argv, metallib_path))
    {
        return EXIT_FAILURE;
    }

    @autoreleasepool
    {
        testKeyContract();
        testInvalidCacheDevices();

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        EXPECT(device != nil);
        if (device == nil)
        {
            return EXIT_FAILURE;
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];
        EXPECT(queue != nil);
        id<MTLLibrary> library = loadLibrary(device, metallib_path);
        id<MTLFunction> function =
            [library newFunctionWithName:@"firestorm_sampler_test"];
        EXPECT(function != nil);

        NSError* pipeline_error = nil;
        id<MTLComputePipelineState> pipeline = function == nil
            ? nil
            : [device newComputePipelineStateWithFunction:function
                                                    error:&pipeline_error];
        if (pipeline == nil)
        {
            std::cerr << "FAIL create sampler pipeline: "
                      << toString(pipeline_error.localizedDescription) << '\n';
            ++gFailures;
        }

        if (queue != nil && pipeline != nil)
        {
            MetalFrameContext frames((__bridge void*)device, 512);
            EXPECT(frames.valid());
            const auto source = uploadSourceTexture(device, queue, frames);
            EXPECT(source.has_value());
            if (source)
            {
                EXPECT(source->valid());
                EXPECT(source->mipLevels() == 1);
                EXPECT(source->usage() == MetalTextureUsage::shader_read);

                // Keep the cache alive through command-buffer completion so
                // its borrowed native handles remain valid by construction.
                MetalSamplerCache cache((__bridge void*)device);
                EXPECT(cache.valid());

                SamplerDesc repeat;
                repeat.s = SamplerAddressMode::repeat;
                repeat.t = SamplerAddressMode::repeat;
                repeat.r = SamplerAddressMode::repeat;
                repeat.mip = SamplerMipFilter::nearest;
                const auto repeat_first = cache.sampler(repeat, source->mipLevels());
                SamplerDesc equivalent = repeat;
                equivalent.mip = SamplerMipFilter::linear;
                const auto repeat_second = cache.sampler(equivalent,
                                                          source->mipLevels());
                SamplerDesc invalid = repeat;
                invalid.maxAnisotropy = 17;
                EXPECT(!cache.sampler(invalid, source->mipLevels()).has_value());
                SamplerDesc clamp = repeat;
                clamp.s = SamplerAddressMode::clamp_to_edge;
                clamp.t = SamplerAddressMode::clamp_to_edge;
                clamp.r = SamplerAddressMode::clamp_to_edge;
                const auto clamp_handle = cache.sampler(clamp,
                                                         source->mipLevels());

                EXPECT(repeat_first.has_value());
                EXPECT(repeat_second == repeat_first);
                EXPECT(clamp_handle.has_value());
                EXPECT(cache.hitCount() == 1);
                EXPECT(cache.missCount() == 2);
                EXPECT(cache.entryCount() == 2);
                if (repeat_first && clamp_handle)
                {
                    runSamplerGpuTest(device,
                                      queue,
                                      pipeline,
                                      frames,
                                      *source,
                                      CachedSamplers{ *repeat_first,
                                                       *clamp_handle });
                }
            }
        }
    }

    if (gFailures != 0)
    {
        std::cerr << gFailures << " Metal sampler test(s) failed\n";
        return EXIT_FAILURE;
    }

    std::cout << "PASS Metal sampler cache and exact GPU sampling\n";
    return EXIT_SUCCESS;
}
