/**
 * @file depth-raster-test-objc.mm
 * @brief Exact depth, cull, and front-winding GPU validation.
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
#include "llmetalstate.h"
#include "llmetaltransfer.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <optional>
#include <string>
#include <utility>

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

using firestorm::metal::CompareFunction;
using firestorm::metal::CullMode;
using firestorm::metal::DepthStateDesc;
using firestorm::metal::DepthStateKeyHash;
using firestorm::metal::FrontFace;
using firestorm::metal::MetalDepthStateCache;
using firestorm::metal::MetalDepthStateHandle;
using firestorm::metal::MetalFrameContext;
using firestorm::metal::MetalFrameLease;
using firestorm::metal::MetalPrivateTexture2D;
using firestorm::metal::MetalTexture2DDescriptor;
using firestorm::metal::MetalTextureReadback;
using firestorm::metal::MetalTextureRegion;
using firestorm::metal::MetalTextureUsage;
using firestorm::metal::MetalTransferBatch;
using firestorm::metal::MetalTransferStatus;
using firestorm::metal::PixelFormat;
using firestorm::metal::RasterStateDesc;
using firestorm::metal::applyRasterState;
using firestorm::metal::createPrivateTexture2D;
using firestorm::metal::makeDepthStateKey;

constexpr std::uint32_t WIDTH  = 4;
constexpr std::uint32_t HEIGHT = 1;
constexpr std::size_t ACTIVE_ROW_BYTES = 16;

constexpr std::array<std::uint8_t, ACTIVE_ROW_BYTES> EXPECTED_PIXELS{
    0, 255, 0, 255,
    255, 0, 0, 255,
    0, 0, 255, 255,
    255, 255, 0, 255,
};

enum class DrawColor : std::uint32_t
{
    green,
    red,
    blue,
    yellow,
};

struct alignas(16) DepthRasterDraw
{
    float         depth;
    std::uint32_t reverseWinding;
    DrawColor     color;
    std::uint32_t unused = 0;
};

static_assert(sizeof(DepthRasterDraw) == 16,
              "Depth raster draw constants must match the Metal shader");

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
              << " status="
              << static_cast<unsigned long>(command_buffer.status)
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
    id<MTLLibrary> library =
        [device newLibraryWithURL:[NSURL fileURLWithPath:native_path]
                            error:&error];
    if (library == nil)
    {
        std::cerr << "FAIL load depth/raster metallib: "
                  << toString(error.localizedDescription) << '\n';
        ++gFailures;
    }
    return library;
}

id<MTLRenderPipelineState> createPipeline(id<MTLDevice> device,
                                          id<MTLLibrary> library)
{
    id<MTLFunction> vertex =
        [library newFunctionWithName:@"firestorm_depth_raster_vertex"];
    id<MTLFunction> fragment =
        [library newFunctionWithName:@"firestorm_depth_raster_fragment"];
    EXPECT(vertex != nil);
    EXPECT(fragment != nil);
    if (vertex == nil || fragment == nil)
    {
        return nil;
    }

    MTLRenderPipelineDescriptor* descriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.label = @"Firestorm depth and raster oracle pipeline";
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

    NSError* error = nil;
    id<MTLRenderPipelineState> pipeline =
        [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (pipeline == nil)
    {
        std::cerr << "FAIL create depth/raster pipeline: "
                  << toString(error.localizedDescription) << '\n';
        ++gFailures;
    }
    return pipeline;
}

void testKeyContract()
{
    const DepthStateDesc default_descriptor;
    const auto default_key = makeDepthStateKey(default_descriptor);
    EXPECT(default_key.has_value());
    if (default_key)
    {
        EXPECT(default_key->compare == CompareFunction::always);
        EXPECT(!default_key->writeEnabled);
    }

    const DepthStateDesc less_write{ CompareFunction::less, true };
    const auto first = makeDepthStateKey(less_write);
    const auto second = makeDepthStateKey(less_write);
    EXPECT(first.has_value());
    EXPECT(second == first);
    if (first && second)
    {
        EXPECT(DepthStateKeyHash{}(*first) == DepthStateKeyHash{}(*second));
    }
    EXPECT(first != default_key);

    DepthStateDesc invalid;
    invalid.compare = static_cast<CompareFunction>(255);
    EXPECT(!makeDepthStateKey(invalid).has_value());
}

void testInvalidNativeInputs()
{
    MetalDepthStateCache null_cache(nullptr);
    EXPECT(!null_cache.valid());
    EXPECT(!null_cache.depthState(DepthStateDesc{}).has_value());
    EXPECT(null_cache.hitCount() == 0);
    EXPECT(null_cache.missCount() == 0);
    EXPECT(null_cache.entryCount() == 0);

    NSObject* not_a_device = [[NSObject alloc] init];
    MetalDepthStateCache wrong_type((__bridge void*)not_a_device);
    EXPECT(!wrong_type.valid());

    EXPECT(!applyRasterState(nullptr, RasterStateDesc{}));
    EXPECT(!applyRasterState((__bridge void*)not_a_device,
                             RasterStateDesc{}));
}

std::optional<MetalPrivateTexture2D>
createTarget(id<MTLDevice> device,
             PixelFormat format,
             const char* label)
{
    MetalTexture2DDescriptor descriptor;
    descriptor.format    = format;
    descriptor.width     = WIDTH;
    descriptor.height    = HEIGHT;
    descriptor.mipLevels = 1;
    descriptor.usage     = MetalTextureUsage::render_target;
    descriptor.label     = label;
    return createPrivateTexture2D((__bridge void*)device, descriptor);
}

bool encodeDraw(MetalFrameContext&         frames,
                const MetalFrameLease&    lease,
                id<MTLRenderCommandEncoder> encoder,
                const DepthRasterDraw&    draw)
{
    const auto allocation =
        frames.allocate(lease.token, sizeof(draw), alignof(DepthRasterDraw));
    EXPECT(allocation.has_value());
    if (!allocation)
    {
        return false;
    }

    std::memcpy(allocation->bytes, &draw, sizeof(draw));
    [encoder setVertexBuffer:(__bridge id<MTLBuffer>)lease.buffer
                      offset:allocation->offset
                     atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:3];
    return true;
}

bool beginCell(id<MTLRenderCommandEncoder> encoder,
               std::uint32_t               x,
               MetalDepthStateHandle       depth_state,
               const RasterStateDesc&      raster_state)
{
    [encoder setScissorRect:MTLScissorRect{ x, 0, 1, 1 }];
    [encoder setDepthStencilState:
        (__bridge id<MTLDepthStencilState>)depth_state];
    const bool applied =
        applyRasterState((__bridge void*)encoder, raster_state);
    EXPECT(applied);
    return applied;
}

void validateReadback(const MetalTextureReadback& readback)
{
    EXPECT(readback.format == PixelFormat::rgba8_unorm);
    EXPECT(readback.region.x == 0);
    EXPECT(readback.region.y == 0);
    EXPECT(readback.region.width == WIDTH);
    EXPECT(readback.region.height == HEIGHT);
    EXPECT(readback.region.mipLevel == 0);
    EXPECT(readback.region.slice == 0);
    EXPECT(readback.bytesPerRow >= ACTIVE_ROW_BYTES);
    EXPECT(readback.bytesPerImage >= readback.bytesPerRow);
    EXPECT(readback.bytes.size() >= readback.bytesPerImage);
    if (readback.bytesPerRow < ACTIVE_ROW_BYTES ||
        readback.bytes.size() < ACTIVE_ROW_BYTES)
    {
        return;
    }

    for (std::size_t offset = 0; offset < ACTIVE_ROW_BYTES; ++offset)
    {
        const std::uint8_t actual =
            std::to_integer<std::uint8_t>(readback.bytes[offset]);
        if (actual != EXPECTED_PIXELS[offset])
        {
            std::cerr << "FAIL depth/raster cell=" << offset / 4
                      << " channel=" << offset % 4
                      << " expected="
                      << static_cast<unsigned>(EXPECTED_PIXELS[offset])
                      << " actual=" << static_cast<unsigned>(actual) << '\n';
            ++gFailures;
        }
    }
}

void runDepthRasterGpuTest(id<MTLDevice> device,
                           id<MTLCommandQueue> queue,
                           id<MTLRenderPipelineState> pipeline)
{
    const auto color = createTarget(device,
                                    PixelFormat::rgba8_unorm,
                                    "Firestorm depth/raster 4x1 color");
    const auto depth = createTarget(device,
                                    PixelFormat::depth32_float,
                                    "Firestorm depth/raster 4x1 depth");
    EXPECT(color.has_value());
    EXPECT(depth.has_value());
    if (!color || !depth)
    {
        return;
    }

    id<MTLTexture> native_color =
        (__bridge id<MTLTexture>)color->nativeHandle();
    id<MTLTexture> native_depth =
        (__bridge id<MTLTexture>)depth->nativeHandle();
    EXPECT(native_color.storageMode == MTLStorageModePrivate);
    EXPECT(native_depth.storageMode == MTLStorageModePrivate);
    EXPECT(native_color.pixelFormat == MTLPixelFormatRGBA8Unorm);
    EXPECT(native_depth.pixelFormat == MTLPixelFormatDepth32Float);

    MetalDepthStateCache cache((__bridge void*)device);
    EXPECT(cache.valid());

    const DepthStateDesc less_write{ CompareFunction::less, true };
    const DepthStateDesc less_no_write{ CompareFunction::less, false };
    const DepthStateDesc always_no_write{ CompareFunction::always, false };
    const auto less_write_first = cache.depthState(less_write);
    const auto less_write_second = cache.depthState(less_write);
    const auto less_no_write_state = cache.depthState(less_no_write);
    const auto always_no_write_state = cache.depthState(always_no_write);

    DepthStateDesc invalid_depth;
    invalid_depth.compare = static_cast<CompareFunction>(255);
    EXPECT(!cache.depthState(invalid_depth).has_value());
    EXPECT(less_write_first.has_value());
    EXPECT(less_write_second == less_write_first);
    EXPECT(less_no_write_state.has_value());
    EXPECT(always_no_write_state.has_value());
    EXPECT(cache.hitCount() == 1);
    EXPECT(cache.missCount() == 3);
    EXPECT(cache.entryCount() == 3);
    if (!less_write_first || !less_no_write_state ||
        !always_no_write_state)
    {
        return;
    }

    MetalFrameContext frames((__bridge void*)device, 512);
    EXPECT(frames.valid());
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
    command_buffer.label = @"Firestorm exact depth and raster validation";

    MTLRenderPassDescriptor* render_pass =
        [MTLRenderPassDescriptor renderPassDescriptor];
    render_pass.colorAttachments[0].texture = native_color;
    render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    render_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    render_pass.depthAttachment.texture = native_depth;
    render_pass.depthAttachment.loadAction = MTLLoadActionClear;
    render_pass.depthAttachment.storeAction = MTLStoreActionDontCare;
    render_pass.depthAttachment.clearDepth = 1.0;

    id<MTLRenderCommandEncoder> encoder =
        [command_buffer renderCommandEncoderWithDescriptor:render_pass];
    EXPECT(encoder != nil);
    if (encoder == nil)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }
    encoder.label = @"Firestorm 4x1 depth/cull/winding atlas";
    [encoder setRenderPipelineState:pipeline];
    [encoder setViewport:MTLViewport{ 0.0, 0.0,
                                     static_cast<double>(WIDTH),
                                     static_cast<double>(HEIGHT),
                                     0.0, 1.0 }];

    RasterStateDesc invalid_raster;
    invalid_raster.cullMode = static_cast<CullMode>(255);
    EXPECT(!applyRasterState((__bridge void*)encoder, invalid_raster));
    invalid_raster = RasterStateDesc{};
    invalid_raster.frontFace = static_cast<FrontFace>(255);
    EXPECT(!applyRasterState((__bridge void*)encoder, invalid_raster));

    bool encoded = true;
    encoded = beginCell(encoder, 0, *less_write_first, RasterStateDesc{}) &&
              encoded;
    encoded = encodeDraw(frames, *lease,
                         encoder, DepthRasterDraw{ 0.25F, 0,
                                                  DrawColor::green }) &&
              encoded;
    encoded = encodeDraw(frames, *lease,
                         encoder, DepthRasterDraw{ 0.75F, 0,
                                                  DrawColor::red }) &&
              encoded;

    encoded = beginCell(encoder, 1, *less_no_write_state,
                        RasterStateDesc{}) && encoded;
    encoded = encodeDraw(frames, *lease,
                         encoder, DepthRasterDraw{ 0.25F, 0,
                                                  DrawColor::green }) &&
              encoded;
    encoded = encodeDraw(frames, *lease,
                         encoder, DepthRasterDraw{ 0.75F, 0,
                                                  DrawColor::red }) &&
              encoded;

    const RasterStateDesc clockwise_back_cull{
        CullMode::back, FrontFace::clockwise
    };
    encoded = beginCell(encoder, 2, *always_no_write_state,
                        clockwise_back_cull) && encoded;
    encoded = encodeDraw(frames, *lease,
                         encoder, DepthRasterDraw{ 0.5F, 0,
                                                  DrawColor::blue }) &&
              encoded;
    encoded = encodeDraw(frames, *lease,
                         encoder, DepthRasterDraw{ 0.5F, 1,
                                                  DrawColor::yellow }) &&
              encoded;

    const RasterStateDesc counter_clockwise_back_cull{
        CullMode::back, FrontFace::counter_clockwise
    };
    encoded = beginCell(encoder, 3, *always_no_write_state,
                        counter_clockwise_back_cull) && encoded;
    encoded = encodeDraw(frames, *lease,
                         encoder, DepthRasterDraw{ 0.5F, 0,
                                                  DrawColor::blue }) &&
              encoded;
    encoded = encodeDraw(frames, *lease,
                         encoder, DepthRasterDraw{ 0.5F, 1,
                                                  DrawColor::yellow }) &&
              encoded;
    [encoder endEncoding];

    if (!encoded)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    std::mutex publication_mutex;
    std::optional<MetalTextureReadback> publication;
    std::uint64_t published_serial = 0;
    dispatch_semaphore_t published = dispatch_semaphore_create(0);

    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             256);
    EXPECT(batch.valid());
    const MetalTextureRegion region{ 0, 0, WIDTH, HEIGHT, 0, 0 };
    EXPECT(batch.readbackTexture2D(
               *color,
               region,
               [&](std::uint64_t serial, MetalTextureReadback readback) {
                   {
                       std::lock_guard<std::mutex> lock(publication_mutex);
                       published_serial = serial;
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

    const auto submission_serial = frames.submit(
        lease->token,
        (__bridge void*)command_buffer,
        std::move(*completion));
    EXPECT(submission_serial.has_value());
    if (!submission_serial)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    {
        std::lock_guard<std::mutex> lock(publication_mutex);
        EXPECT(!publication.has_value());
    }
    [command_buffer commit];
    requireSignal(published, command_buffer, "depth/raster atlas readback");
    EXPECT(command_buffer.status == MTLCommandBufferStatusCompleted);
    EXPECT(command_buffer.error == nil);

    std::lock_guard<std::mutex> lock(publication_mutex);
    EXPECT(publication.has_value());
    EXPECT(published_serial == *submission_serial);
    if (publication)
    {
        validateReadback(*publication);
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
        testInvalidNativeInputs();

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        EXPECT(device != nil);
        if (device == nil)
        {
            return EXIT_FAILURE;
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];
        EXPECT(queue != nil);
        id<MTLLibrary> library = loadLibrary(device, metallib_path);
        id<MTLRenderPipelineState> pipeline =
            library == nil ? nil : createPipeline(device, library);
        if (queue != nil && pipeline != nil)
        {
            runDepthRasterGpuTest(device, queue, pipeline);
        }
    }

    if (gFailures != 0)
    {
        std::cerr << gFailures << " Metal depth/raster test(s) failed\n";
        return EXIT_FAILURE;
    }

    std::cout << "PASS Metal depth cache and exact depth/cull/winding atlas\n";
    return EXIT_SUCCESS;
}
