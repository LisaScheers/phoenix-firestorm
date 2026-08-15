/**
 * @file color-gamma-test-objc.mm
 * @brief Exact linear, sRGB attachment, decode, and final-display validation.
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

#include "llmetalpipeline.h"
#include "llmetalrenderpass.h"
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

using firestorm::metal::AttachmentLoadAction;
using firestorm::metal::AttachmentStoreAction;
using firestorm::metal::BlendAttachmentDesc;
using firestorm::metal::MetalColorAttachmentDesc;
using firestorm::metal::MetalFrameContext;
using firestorm::metal::MetalPrivateTexture;
using firestorm::metal::MetalRenderPassDesc;
using firestorm::metal::MetalRenderPipelineFamilyCache;
using firestorm::metal::MetalRenderPipelineFamilyDesc;
using firestorm::metal::MetalRenderPipelineHandle;
using firestorm::metal::MetalRenderTarget;
using firestorm::metal::MetalTextureDescriptor;
using firestorm::metal::MetalTextureReadback;
using firestorm::metal::MetalTextureRegion;
using firestorm::metal::MetalTextureUsage;
using firestorm::metal::MetalTransferBatch;
using firestorm::metal::MetalTransferStatus;
using firestorm::metal::PixelFormat;
using firestorm::metal::beginRenderPass;
using firestorm::metal::createPrivateTexture;
using firestorm::metal::makeRenderTarget;

constexpr std::size_t RESOURCE_COUNT = 4;
constexpr std::size_t READBACK_BYTES_PER_IMAGE = 256;
constexpr std::size_t READBACK_BUDGET =
    RESOURCE_COUNT * READBACK_BYTES_PER_IMAGE;
constexpr const char* VERTEX_FUNCTION = "firestorm_color_gamma_vertex";
constexpr const char* CONSTANT_FRAGMENT =
    "firestorm_color_gamma_constant_fragment";
constexpr const char* COPY_FRAGMENT =
    "firestorm_color_gamma_copy_fragment";
constexpr const char* FINAL_FRAGMENT =
    "firestorm_color_gamma_final_fragment";

constexpr std::array<std::uint8_t, 4> LINEAR_BYTES{ 17, 13, 7, 191 };
constexpr std::array<std::uint8_t, 4> SRGB_BYTES{ 73, 64, 46, 191 };
constexpr std::array<std::uint8_t, 4> BGRA_BYTES{ 46, 64, 73, 191 };

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
        std::cerr << "FAIL load color/gamma metallib: "
                  << toString(error.localizedDescription) << '\n';
        ++gFailures;
    }
    return library;
}

std::optional<MetalPrivateTexture>
createColorTexture(id<MTLDevice> device,
                   PixelFormat format,
                   MetalTextureUsage usage,
                   const std::string& label)
{
    MetalTextureDescriptor descriptor;
    descriptor.format = format;
    descriptor.width = 1;
    descriptor.height = 1;
    descriptor.mipLevels = 1;
    descriptor.usage = usage;
    descriptor.label = label;
    return createPrivateTexture((__bridge void*)device, descriptor);
}

MetalRenderPipelineFamilyDesc
pipelineDescriptor(const char* fragment_function, PixelFormat format)
{
    MetalRenderPipelineFamilyDesc descriptor;
    descriptor.vertexFunction = VERTEX_FUNCTION;
    descriptor.fragmentFunction = fragment_function;
    descriptor.colorFormats = { format };
    return descriptor;
}

bool encodePass(id<MTLCommandBuffer> command_buffer,
                const MetalRenderTarget& target,
                MetalRenderPipelineHandle pipeline,
                const MetalPrivateTexture* source,
                const char* label)
{
    MetalRenderPassDesc descriptor;
    descriptor.colors = { MetalColorAttachmentDesc{
        AttachmentLoadAction::dont_care,
        AttachmentStoreAction::store,
        {}
    } };
    descriptor.label = label;

    auto pass = beginRenderPass((__bridge void*)command_buffer,
                                target,
                                descriptor);
    EXPECT(pass.has_value());
    if (!pass)
    {
        return false;
    }

    id<MTLRenderCommandEncoder> encoder =
        (__bridge id<MTLRenderCommandEncoder>)pass->encoder();
    EXPECT(encoder != nil);
    if (encoder == nil)
    {
        return false;
    }

    [encoder setRenderPipelineState:
        (__bridge id<MTLRenderPipelineState>)pipeline];
    [encoder setViewport:MTLViewport{ 0.0, 0.0, 1.0, 1.0, 0.0, 1.0 }];
    if (source != nullptr)
    {
        [encoder setFragmentTexture:
            (__bridge id<MTLTexture>)source->nativeHandle()
                             atIndex:0];
    }
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:3];
    EXPECT(pass->end());
    return true;
}

void validateReadback(const MetalTextureReadback& readback,
                      PixelFormat format,
                      const std::array<std::uint8_t, 4>& expected,
                      std::uint8_t rgb_tolerance,
                      const char* label)
{
    EXPECT(readback.format == format);
    EXPECT(readback.region.x == 0);
    EXPECT(readback.region.y == 0);
    EXPECT(readback.region.width == 1);
    EXPECT(readback.region.height == 1);
    EXPECT(readback.region.mipLevel == 0);
    EXPECT(readback.region.slice == 0);
    EXPECT(readback.bytesPerRow == READBACK_BYTES_PER_IMAGE);
    EXPECT(readback.bytesPerImage == READBACK_BYTES_PER_IMAGE);
    EXPECT(readback.bytes.size() == READBACK_BYTES_PER_IMAGE);
    if (readback.bytes.size() < expected.size())
    {
        return;
    }

    constexpr const char* channels[] = { "0", "1", "2", "A" };
    for (std::size_t channel = 0; channel < expected.size(); ++channel)
    {
        const std::uint8_t actual =
            std::to_integer<std::uint8_t>(readback.bytes[channel]);
        const std::uint8_t tolerance = channel == 3 ? 0 : rgb_tolerance;
        const int difference = static_cast<int>(actual) -
                               static_cast<int>(expected[channel]);
        if (difference < -static_cast<int>(tolerance) ||
            difference > static_cast<int>(tolerance))
        {
            std::cerr << "FAIL " << label << " channel=" << channels[channel]
                      << " expected=" << static_cast<unsigned>(expected[channel])
                      << " tolerance=" << static_cast<unsigned>(tolerance)
                      << " actual=" << static_cast<unsigned>(actual) << '\n';
            ++gFailures;
        }
    }
}

void runColorGammaOracle(id<MTLDevice> device,
                         id<MTLLibrary> library,
                         id<MTLCommandQueue> queue)
{
    constexpr MetalTextureUsage intermediate_usage =
        MetalTextureUsage::render_target | MetalTextureUsage::shader_read;
    const auto linear = createColorTexture(
        device,
        PixelFormat::rgba8_unorm,
        intermediate_usage,
        "Firestorm color/gamma linear constant");
    const auto srgb = createColorTexture(
        device,
        PixelFormat::rgba8_unorm_srgb,
        intermediate_usage,
        "Firestorm color/gamma automatic sRGB encode");
    const auto decoded = createColorTexture(
        device,
        PixelFormat::rgba8_unorm,
        intermediate_usage,
        "Firestorm color/gamma automatic sRGB decode");
    const auto display = createColorTexture(
        device,
        PixelFormat::bgra8_unorm,
        MetalTextureUsage::render_target,
        "Firestorm color/gamma manual final display encode");
    EXPECT(linear.has_value());
    EXPECT(srgb.has_value());
    EXPECT(decoded.has_value());
    EXPECT(display.has_value());
    if (!linear || !srgb || !decoded || !display)
    {
        return;
    }

    const auto linear_target = makeRenderTarget({ *linear });
    const auto srgb_target = makeRenderTarget({ *srgb });
    const auto decoded_target = makeRenderTarget({ *decoded });
    const auto display_target = makeRenderTarget({ *display });
    EXPECT(linear_target.has_value());
    EXPECT(srgb_target.has_value());
    EXPECT(decoded_target.has_value());
    EXPECT(display_target.has_value());
    if (!linear_target || !srgb_target || !decoded_target || !display_target)
    {
        return;
    }

    MetalRenderPipelineFamilyCache linear_pipeline_cache(
        (__bridge void*)device,
        (__bridge void*)library,
        pipelineDescriptor(CONSTANT_FRAGMENT, PixelFormat::rgba8_unorm));
    MetalRenderPipelineFamilyCache srgb_pipeline_cache(
        (__bridge void*)device,
        (__bridge void*)library,
        pipelineDescriptor(COPY_FRAGMENT, PixelFormat::rgba8_unorm_srgb));
    MetalRenderPipelineFamilyCache decoded_pipeline_cache(
        (__bridge void*)device,
        (__bridge void*)library,
        pipelineDescriptor(COPY_FRAGMENT, PixelFormat::rgba8_unorm));
    MetalRenderPipelineFamilyCache final_pipeline_cache(
        (__bridge void*)device,
        (__bridge void*)library,
        pipelineDescriptor(FINAL_FRAGMENT, PixelFormat::bgra8_unorm));
    EXPECT(linear_pipeline_cache.valid());
    EXPECT(srgb_pipeline_cache.valid());
    EXPECT(decoded_pipeline_cache.valid());
    EXPECT(final_pipeline_cache.valid());

    const auto linear_pipeline =
        linear_pipeline_cache.pipeline({ BlendAttachmentDesc{} });
    const auto srgb_pipeline =
        srgb_pipeline_cache.pipeline({ BlendAttachmentDesc{} });
    const auto decoded_pipeline =
        decoded_pipeline_cache.pipeline({ BlendAttachmentDesc{} });
    const auto final_pipeline =
        final_pipeline_cache.pipeline({ BlendAttachmentDesc{} });
    EXPECT(linear_pipeline.has_value());
    EXPECT(srgb_pipeline.has_value());
    EXPECT(decoded_pipeline.has_value());
    EXPECT(final_pipeline.has_value());

    if (!linear_pipeline || !srgb_pipeline || !decoded_pipeline ||
        !final_pipeline)
    {
        return;
    }

    MetalFrameContext frames((__bridge void*)device, 256);
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
    command_buffer.label = @"Firestorm four-pass color/gamma oracle";

    bool encoded = encodePass(command_buffer,
                              *linear_target,
                              *linear_pipeline,
                              nullptr,
                              "Firestorm linear RGBA8 constant");
    encoded = encodePass(command_buffer,
                         *srgb_target,
                         *srgb_pipeline,
                         &*linear,
                         "Firestorm automatic sRGB attachment encode") &&
              encoded;
    encoded = encodePass(command_buffer,
                         *decoded_target,
                         *decoded_pipeline,
                         &*srgb,
                         "Firestorm automatic sRGB texture decode") &&
              encoded;
    encoded = encodePass(command_buffer,
                         *display_target,
                         *final_pipeline,
                         &*linear,
                         "Firestorm manual final-display gamma encode") &&
              encoded;
    EXPECT(encoded);
    if (!encoded)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    std::mutex publication_mutex;
    std::array<std::optional<MetalTextureReadback>, RESOURCE_COUNT> readbacks;
    std::array<std::uint64_t, RESOURCE_COUNT> publication_serials{};
    std::vector<std::size_t> publication_order;
    publication_order.reserve(RESOURCE_COUNT);
    dispatch_semaphore_t published = dispatch_semaphore_create(0);

    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             READBACK_BUDGET);
    EXPECT(batch.valid());
    const MetalTextureRegion region{ 0, 0, 1, 1, 0, 0 };
    const std::array<MetalPrivateTexture, RESOURCE_COUNT> textures{
        *linear, *srgb, *decoded, *display
    };
    for (std::size_t index = 0; index < textures.size(); ++index)
    {
        const auto status = batch.readbackTexture(
            textures[index],
            region,
            [&, index](std::uint64_t serial, MetalTextureReadback readback) {
                {
                    std::lock_guard<std::mutex> lock(publication_mutex);
                    publication_order.push_back(index);
                    publication_serials[index] = serial;
                    readbacks[index] = std::move(readback);
                }
                dispatch_semaphore_signal(published);
            });
        EXPECT(status == MetalTransferStatus::encoded);
        if (status != MetalTransferStatus::encoded)
        {
            return;
        }
    }

    auto completion = batch.finish();
    EXPECT(completion.has_value());
    if (!completion)
    {
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
        EXPECT(publication_order.empty());
    }
    [command_buffer commit];
    for (std::size_t index = 0; index < RESOURCE_COUNT; ++index)
    {
        requireSignal(published, command_buffer, "color/gamma readback");
    }
    EXPECT(command_buffer.status == MTLCommandBufferStatusCompleted);
    EXPECT(command_buffer.error == nil);

    std::lock_guard<std::mutex> lock(publication_mutex);
    EXPECT(publication_order ==
           std::vector<std::size_t>({ 0, 1, 2, 3 }));
    for (std::size_t index = 0; index < RESOURCE_COUNT; ++index)
    {
        EXPECT(readbacks[index].has_value());
        EXPECT(publication_serials[index] == *submission_serial);
    }
    if (readbacks[0])
    {
        validateReadback(*readbacks[0],
                         PixelFormat::rgba8_unorm,
                         LINEAR_BYTES,
                         0,
                         "linear RGBA8 constant");
    }
    if (readbacks[1])
    {
        validateReadback(*readbacks[1],
                         PixelFormat::rgba8_unorm_srgb,
                         SRGB_BYTES,
                         1,
                         "automatic sRGB attachment encode");
    }
    if (readbacks[2])
    {
        validateReadback(*readbacks[2],
                         PixelFormat::rgba8_unorm,
                         LINEAR_BYTES,
                         1,
                         "automatic sRGB texture decode");
    }
    if (readbacks[3])
    {
        validateReadback(*readbacks[3],
                         PixelFormat::bgra8_unorm,
                         BGRA_BYTES,
                         1,
                         "manual BGRA final-display encode");
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
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        EXPECT(device != nil);
        if (device == nil)
        {
            return EXIT_FAILURE;
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];
        EXPECT(queue != nil);
        id<MTLLibrary> library = loadLibrary(device, metallib_path);
        if (queue != nil && library != nil)
        {
            runColorGammaOracle(device, library, queue);
        }
    }

    if (gFailures != 0)
    {
        std::cerr << gFailures << " Metal color/gamma test(s) failed\n";
        return EXIT_FAILURE;
    }

    std::cout << "PASS Metal linear/sRGB/final-display color contract\n";
    return EXIT_SUCCESS;
}
