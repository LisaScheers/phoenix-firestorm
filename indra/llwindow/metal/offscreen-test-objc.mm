/**
 * @file offscreen-test-objc.mm
 * @brief Deterministic Metal render-target and readback validation.
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

#include <array>
#include <cstdint>
#include <iostream>
#include <memory>
#include <string>

namespace
{

constexpr NSUInteger WIDTH = 2;
constexpr NSUInteger HEIGHT = 2;
constexpr NSUInteger BYTES_PER_PIXEL = 4;
constexpr NSUInteger BYTES_PER_ROW = 256;
constexpr NSUInteger BUFFER_SIZE = BYTES_PER_ROW * HEIGHT;

struct CompletionResult
{
    MTLCommandBufferStatus status = MTLCommandBufferStatusNotEnqueued;
    std::string error;
};

std::string toString(NSString* value)
{
    if (!value)
    {
        return {};
    }

    const char* utf8 = value.UTF8String;
    return utf8 ? utf8 : std::string();
}

std::string toString(NSError* error)
{
    if (!error)
    {
        return {};
    }

    return toString(error.localizedDescription) + " (" +
        toString(error.domain) + " " + std::to_string(error.code) + ")";
}

const char* toString(MTLCommandBufferStatus status)
{
    switch (status)
    {
        case MTLCommandBufferStatusNotEnqueued:
            return "not enqueued";
        case MTLCommandBufferStatusEnqueued:
            return "enqueued";
        case MTLCommandBufferStatusCommitted:
            return "committed";
        case MTLCommandBufferStatusScheduled:
            return "scheduled";
        case MTLCommandBufferStatusCompleted:
            return "completed";
        case MTLCommandBufferStatusError:
            return "error";
    }

    return "unknown";
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

int fail(const std::string& stage, const std::string& message, id<MTLDevice> device)
{
    std::cerr << "FAIL offscreen_orientation stage=\"" << stage << "\"";
    if (device)
    {
        std::cerr << " device=\"" << toString(device.name) << "\"";
    }
    std::cerr << " error=\"" << message << "\"\n";
    return 1;
}

int run(const std::string& metallib_path)
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device)
    {
        return fail("device", "this Mac does not expose a Metal device", nil);
    }

    NSString* library_path = [NSString stringWithUTF8String:metallib_path.c_str()];
    if (!library_path)
    {
        return fail("library", "the metallib path is not valid UTF-8", device);
    }

    NSError* library_error = nil;
    id<MTLLibrary> library = [device
        newLibraryWithURL:[NSURL fileURLWithPath:library_path]
        error:&library_error];
    if (!library)
    {
        return fail("library", toString(library_error), device);
    }

    id<MTLFunction> vertex_function =
        [library newFunctionWithName:@"firestorm_offscreen_orientation_vertex"];
    id<MTLFunction> fragment_function =
        [library newFunctionWithName:@"firestorm_offscreen_orientation_fragment"];
    if (!vertex_function || !fragment_function)
    {
        return fail("pipeline", "the metallib is missing an offscreen entry point", device);
    }

    MTLRenderPipelineDescriptor* pipeline_descriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    pipeline_descriptor.label = @"Firestorm offscreen orientation pipeline";
    pipeline_descriptor.vertexFunction = vertex_function;
    pipeline_descriptor.fragmentFunction = fragment_function;
    pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;

    NSError* pipeline_error = nil;
    id<MTLRenderPipelineState> pipeline = [device
        newRenderPipelineStateWithDescriptor:pipeline_descriptor
        error:&pipeline_error];
    if (!pipeline)
    {
        return fail("pipeline", toString(pipeline_error), device);
    }

    MTLTextureDescriptor* texture_descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:WIDTH
        height:HEIGHT
        mipmapped:NO];
    texture_descriptor.storageMode = MTLStorageModePrivate;
    texture_descriptor.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> render_target = [device newTextureWithDescriptor:texture_descriptor];
    if (!render_target)
    {
        return fail("texture", "could not create the private render target", device);
    }
    render_target.label = @"Firestorm 2x2 orientation render target";

    id<MTLBuffer> readback = [device
        newBufferWithLength:BUFFER_SIZE
        options:MTLResourceStorageModeShared];
    if (!readback)
    {
        return fail("readback", "could not create the shared readback buffer", device);
    }
    readback.label = @"Firestorm 2x2 orientation readback";

    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue)
    {
        return fail("queue", "could not create the command queue", device);
    }

    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    if (!command_buffer)
    {
        return fail("command buffer", "could not create a command buffer", device);
    }
    command_buffer.label = @"Firestorm offscreen orientation command buffer";

    MTLRenderPassDescriptor* render_pass = [MTLRenderPassDescriptor renderPassDescriptor];
    render_pass.colorAttachments[0].texture = render_target;
    render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    render_pass.colorAttachments[0].clearColor =
        MTLClearColorMake(0.25, 0.5, 0.75, 1.0);

    id<MTLRenderCommandEncoder> render_encoder =
        [command_buffer renderCommandEncoderWithDescriptor:render_pass];
    if (!render_encoder)
    {
        return fail("render encoder", "could not create the render encoder", device);
    }
    render_encoder.label = @"Firestorm offscreen orientation render encoder";
    [render_encoder setRenderPipelineState:pipeline];
    [render_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [render_encoder endEncoding];

    id<MTLBlitCommandEncoder> blit_encoder = [command_buffer blitCommandEncoder];
    if (!blit_encoder)
    {
        return fail("blit encoder", "could not create the blit encoder", device);
    }
    blit_encoder.label = @"Firestorm offscreen orientation readback encoder";
    [blit_encoder
        copyFromTexture:render_target
        sourceSlice:0
        sourceLevel:0
        sourceOrigin:MTLOriginMake(0, 0, 0)
        sourceSize:MTLSizeMake(WIDTH, HEIGHT, 1)
        toBuffer:readback
        destinationOffset:0
        destinationBytesPerRow:BYTES_PER_ROW
        destinationBytesPerImage:BUFFER_SIZE];
    [blit_encoder endEncoding];

    auto completion = std::make_shared<CompletionResult>();
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [command_buffer addCompletedHandler:^(id<MTLCommandBuffer> completed_buffer) {
        completion->status = completed_buffer.status;
        completion->error = toString(completed_buffer.error);
        dispatch_semaphore_signal(finished);
    }];
    [command_buffer commit];

    const dispatch_time_t deadline =
        dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
    if (dispatch_semaphore_wait(finished, deadline) != 0)
    {
        return fail("completion", "timed out after five seconds", device);
    }
    if (completion->status != MTLCommandBufferStatusCompleted ||
        !completion->error.empty())
    {
        const std::string message = "status=" +
            std::string(toString(completion->status)) +
            (completion->error.empty() ? std::string() : " " + completion->error);
        return fail("completion", message, device);
    }

    constexpr std::array<std::array<std::array<std::uint8_t, 4>, 2>, 2> expected{{
        {{{255, 0, 0, 255}, {0, 255, 0, 255}}},
        {{{0, 0, 255, 255}, {255, 255, 255, 255}}},
    }};
    const auto* bytes = static_cast<const std::uint8_t*>(readback.contents);
    NSUInteger mismatched_channels = 0;
    NSUInteger first_x = 0;
    NSUInteger first_y = 0;
    NSUInteger first_channel = 0;
    for (NSUInteger y = 0; y < HEIGHT; ++y)
    {
        for (NSUInteger x = 0; x < WIDTH; ++x)
        {
            for (NSUInteger channel = 0; channel < BYTES_PER_PIXEL; ++channel)
            {
                const NSUInteger offset = y * BYTES_PER_ROW +
                    x * BYTES_PER_PIXEL + channel;
                if (bytes[offset] != expected[y][x][channel])
                {
                    if (mismatched_channels == 0)
                    {
                        first_x = x;
                        first_y = y;
                        first_channel = channel;
                    }
                    ++mismatched_channels;
                }
            }
        }
    }

    if (mismatched_channels != 0)
    {
        const NSUInteger pixel_offset =
            first_y * BYTES_PER_ROW + first_x * BYTES_PER_PIXEL;
        std::cerr << "FAIL offscreen_orientation "
                  << "pipeline=\"Firestorm offscreen orientation pipeline\" "
                  << "pixel=(" << first_x << ',' << first_y << ") "
                  << "row_order=top-to-bottom expected=("
                  << static_cast<unsigned>(expected[first_y][first_x][0]) << ','
                  << static_cast<unsigned>(expected[first_y][first_x][1]) << ','
                  << static_cast<unsigned>(expected[first_y][first_x][2]) << ','
                  << static_cast<unsigned>(expected[first_y][first_x][3]) << ") actual=("
                  << static_cast<unsigned>(bytes[pixel_offset]) << ','
                  << static_cast<unsigned>(bytes[pixel_offset + 1]) << ','
                  << static_cast<unsigned>(bytes[pixel_offset + 2]) << ','
                  << static_cast<unsigned>(bytes[pixel_offset + 3]) << ") "
                  << "first_channel=" << first_channel << ' '
                  << "buffer_offset=" << pixel_offset << ' '
                  << "bytes_per_row=" << BYTES_PER_ROW << ' '
                  << "mismatched_channels=" << mismatched_channels << '\n';
        return 1;
    }

    std::cout << "PASS offscreen_orientation device=\"" << toString(device.name)
              << "\" size=2x2 format=rgba8unorm row_order=top-to-bottom"
              << " bytes_per_row=" << BYTES_PER_ROW << '\n';
    return 0;
}

} // namespace

int main(int argc, const char* argv[])
{
    @autoreleasepool
    {
        std::string metallib_path;
        if (!parseOptions(argc, argv, metallib_path))
        {
            return 2;
        }
        return run(metallib_path);
    }
}
