/**
 * @file mrt-test-objc.mm
 * @brief Bounded MRT, depth-only, cache, and exact GPU validation.
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
using firestorm::metal::BlendFactor;
using firestorm::metal::ColorWriteMask;
using firestorm::metal::CompareFunction;
using firestorm::metal::DepthStateDesc;
using firestorm::metal::MetalClearColor;
using firestorm::metal::MetalColorAttachmentDesc;
using firestorm::metal::MetalDepthAttachmentDesc;
using firestorm::metal::MetalDepthStateCache;
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

constexpr std::size_t COLOR_COUNT = 4;
constexpr std::size_t READBACK_COUNT = COLOR_COUNT + 1;
constexpr std::size_t READBACK_ROW_BYTES = 256;
constexpr std::size_t READBACK_BUDGET =
    READBACK_COUNT * READBACK_ROW_BYTES;
constexpr const char* VERTEX_FUNCTION = "firestorm_mrt_vertex";
constexpr const char* MRT_FRAGMENT_FUNCTION = "firestorm_mrt_fragment";
constexpr const char* DEPTH_FRAGMENT_FUNCTION =
    "firestorm_mrt_depth_fragment";

constexpr std::array<PixelFormat, COLOR_COUNT> COLOR_FORMATS{
    PixelFormat::rgba8_unorm,
    PixelFormat::bgra8_unorm,
    PixelFormat::rgba8_unorm,
    PixelFormat::bgra8_unorm,
};

constexpr std::array<std::array<std::uint8_t, 4>, COLOR_COUNT>
EXPECTED_COLOR_BYTES{
    std::array<std::uint8_t, 4>{ 0xff, 0x00, 0x00, 0xff },
    std::array<std::uint8_t, 4>{ 0xff, 0xff, 0x00, 0xff },
    std::array<std::uint8_t, 4>{ 0xff, 0x00, 0xff, 0xff },
    std::array<std::uint8_t, 4>{ 0x00, 0xff, 0x00, 0xff },
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
    return command_buffer == nil || command_buffer.error == nil
        ? std::string()
        : toString(command_buffer.error.localizedDescription);
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

void commitAndWait(id<MTLCommandBuffer> command_buffer,
                   const char* operation)
{
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    [command_buffer addCompletedHandler:^(id<MTLCommandBuffer>) {
        dispatch_semaphore_signal(completed);
    }];
    [command_buffer commit];
    requireSignal(completed, command_buffer, operation);
    EXPECT(command_buffer.status == MTLCommandBufferStatusCompleted);
    EXPECT(command_buffer.error == nil);
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
    NSString* native_path = [[NSString alloc]
        initWithBytes:path.data()
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
        std::cerr << "FAIL load MRT metallib: "
                  << toString(error.localizedDescription) << '\n';
        ++gFailures;
    }
    return library;
}

std::optional<MetalPrivateTexture>
createTexture(id<MTLDevice> device,
              PixelFormat format,
              std::uint32_t width,
              std::uint32_t height,
              const std::string& label)
{
    MetalTextureDescriptor descriptor;
    descriptor.format = format;
    descriptor.width = width;
    descriptor.height = height;
    descriptor.usage = MetalTextureUsage::render_target;
    descriptor.label = label;
    return createPrivateTexture((__bridge void*)device, descriptor);
}

std::optional<std::array<MetalPrivateTexture, COLOR_COUNT>>
createColors(id<MTLDevice> device, std::uint32_t width, std::uint32_t height)
{
    std::array<MetalPrivateTexture, COLOR_COUNT> colors;
    for (std::size_t index = 0; index < colors.size(); ++index)
    {
        const auto color = createTexture(
            device,
            COLOR_FORMATS[index],
            width,
            height,
            "Firestorm MRT color " + std::to_string(index));
        if (!color)
        {
            return std::nullopt;
        }
        colors[index] = *color;
    }
    return colors;
}

std::vector<MetalPrivateTexture> colorVector(
    const std::array<MetalPrivateTexture, COLOR_COUNT>& colors)
{
    return std::vector<MetalPrivateTexture>(colors.begin(), colors.end());
}

std::vector<MetalColorAttachmentDesc> colorPassDescriptors()
{
    std::vector<MetalColorAttachmentDesc> descriptors(COLOR_COUNT);
    for (MetalColorAttachmentDesc& descriptor : descriptors)
    {
        descriptor.load = AttachmentLoadAction::clear;
        descriptor.store = AttachmentStoreAction::store;
        descriptor.clear = MetalClearColor{ 0.0, 0.0, 0.0, 1.0 };
    }
    descriptors[1].clear = MetalClearColor{ 0.0, 0.0, 1.0, 1.0 };
    descriptors[2].clear = MetalClearColor{ 0.125, 0.0, 0.25, 1.0 };
    descriptors[3].clear = MetalClearColor{ 0.0, 0.375, 0.0, 1.0 };
    return descriptors;
}

std::vector<BlendAttachmentDesc> blendDescriptors()
{
    std::vector<BlendAttachmentDesc> descriptors(COLOR_COUNT);
    descriptors[1].blendingEnabled = true;
    descriptors[1].sourceRGBFactor = BlendFactor::one;
    descriptors[1].destinationRGBFactor = BlendFactor::one;
    descriptors[2].writeMask = ColorWriteMask::red | ColorWriteMask::blue;
    descriptors[3].writeMask = ColorWriteMask::green;
    return descriptors;
}

MetalRenderPipelineFamilyDesc mrtFamilyDescriptor()
{
    MetalRenderPipelineFamilyDesc descriptor;
    descriptor.vertexFunction = VERTEX_FUNCTION;
    descriptor.fragmentFunction = MRT_FRAGMENT_FUNCTION;
    descriptor.colorFormats.assign(COLOR_FORMATS.begin(), COLOR_FORMATS.end());
    return descriptor;
}

MetalRenderPipelineFamilyDesc depthFamilyDescriptor()
{
    MetalRenderPipelineFamilyDesc descriptor;
    descriptor.vertexFunction = VERTEX_FUNCTION;
    descriptor.fragmentFunction = DEPTH_FRAGMENT_FUNCTION;
    descriptor.colorFormats.clear();
    descriptor.depthFormat = PixelFormat::depth32_float;
    return descriptor;
}

void expectInvalidFamily(MetalRenderPipelineFamilyCache& cache)
{
    EXPECT(!cache.valid());
    EXPECT(!cache.pipeline({}).has_value());
    EXPECT(cache.hitCount() == 0);
    EXPECT(cache.missCount() == 0);
    EXPECT(cache.entryCount() == 0);
}

void testPipelineContract(id<MTLDevice> device, id<MTLLibrary> library)
{
    MetalRenderPipelineFamilyCache cache(
        (__bridge void*)device,
        (__bridge void*)library,
        mrtFamilyDescriptor());
    EXPECT(cache.valid());
    if (!cache.valid())
    {
        return;
    }

    auto descriptors = blendDescriptors();
    EXPECT(!cache.pipeline({ descriptors[0] }).has_value());
    EXPECT(cache.hitCount() == 0);
    EXPECT(cache.missCount() == 0);
    EXPECT(cache.entryCount() == 0);

    auto invalid = descriptors;
    invalid[2].sourceAlphaFactor = static_cast<BlendFactor>(255);
    EXPECT(!cache.pipeline(invalid).has_value());
    EXPECT(cache.hitCount() == 0);
    EXPECT(cache.missCount() == 0);
    EXPECT(cache.entryCount() == 0);

    const auto first = cache.pipeline(descriptors);
    EXPECT(first.has_value());
    EXPECT(cache.hitCount() == 0);
    EXPECT(cache.missCount() == 1);
    EXPECT(cache.entryCount() == 1);

    auto equivalent = descriptors;
    equivalent[0].sourceRGBFactor = BlendFactor::destination_color;
    equivalent[0].destinationAlphaFactor =
        BlendFactor::one_minus_source_alpha;
    const auto second = cache.pipeline(equivalent);
    EXPECT(second == first);
    EXPECT(cache.hitCount() == 1);
    EXPECT(cache.missCount() == 1);
    EXPECT(cache.entryCount() == 1);

    auto no_colors = mrtFamilyDescriptor();
    no_colors.colorFormats.clear();
    MetalRenderPipelineFamilyCache no_attachment_cache(
        (__bridge void*)device, (__bridge void*)library, no_colors);
    expectInvalidFamily(no_attachment_cache);

    auto too_many = mrtFamilyDescriptor();
    too_many.colorFormats.push_back(PixelFormat::rgba8_unorm);
    MetalRenderPipelineFamilyCache too_many_cache(
        (__bridge void*)device, (__bridge void*)library, too_many);
    expectInvalidFamily(too_many_cache);

    MetalRenderPipelineFamilyCache depth_cache(
        (__bridge void*)device,
        (__bridge void*)library,
        depthFamilyDescriptor());
    EXPECT(depth_cache.valid());
    const auto depth_pipeline = depth_cache.pipeline({});
    EXPECT(depth_pipeline.has_value());
    EXPECT(depth_cache.pipeline({}) == depth_pipeline);
    EXPECT(!depth_cache.pipeline({ BlendAttachmentDesc{} }).has_value());
    EXPECT(depth_cache.hitCount() == 1);
    EXPECT(depth_cache.missCount() == 1);
    EXPECT(depth_cache.entryCount() == 1);
}

void testTargetAndPassContract(id<MTLDevice> device,
                               id<MTLCommandQueue> queue)
{
    const auto colors = createColors(device, 1, 1);
    const auto depth = createTexture(
        device, PixelFormat::depth32_float, 1, 1,
        "Firestorm MRT target-contract depth");
    EXPECT(colors.has_value());
    EXPECT(depth.has_value());
    if (!colors || !depth)
    {
        return;
    }

    const auto target = makeRenderTarget(colorVector(*colors), *depth);
    EXPECT(target.has_value());
    if (!target)
    {
        return;
    }
    EXPECT(target->valid());
    EXPECT(target->width() == 1);
    EXPECT(target->height() == 1);
    EXPECT(target->sampleCount() == 1);
    EXPECT(target->colorCount() == COLOR_COUNT);
    for (std::size_t index = 0; index < COLOR_COUNT; ++index)
    {
        EXPECT(target->colorFormat(index) == COLOR_FORMATS[index]);
        EXPECT(target->colorTexture(index).has_value());
        if (target->colorTexture(index))
        {
            EXPECT(target->colorTexture(index)->nativeHandle() ==
                   (*colors)[index].nativeHandle());
        }
    }
    EXPECT(!target->colorFormat(COLOR_COUNT).has_value());
    EXPECT(!target->colorTexture(COLOR_COUNT).has_value());
    EXPECT(target->depthFormat() == PixelFormat::depth32_float);

    auto duplicate = colorVector(*colors);
    duplicate[3] = duplicate[0];
    EXPECT(!makeRenderTarget(std::move(duplicate), *depth).has_value());

    auto too_many = colorVector(*colors);
    too_many.push_back((*colors)[0]);
    EXPECT(!makeRenderTarget(std::move(too_many), *depth).has_value());

    const auto mismatched = createTexture(
        device, PixelFormat::rgba8_unorm, 2, 1,
        "Firestorm invalid mismatched MRT extent");
    EXPECT(mismatched.has_value());
    if (mismatched)
    {
        auto mismatched_colors = colorVector(*colors);
        mismatched_colors[2] = *mismatched;
        EXPECT(!makeRenderTarget(std::move(mismatched_colors), *depth)
                    .has_value());
    }

    const auto depth_only = makeRenderTarget({}, *depth);
    EXPECT(depth_only.has_value());
    if (depth_only)
    {
        EXPECT(depth_only->valid());
        EXPECT(depth_only->colorCount() == 0);
        EXPECT(depth_only->width() == 1);
        EXPECT(depth_only->height() == 1);
        EXPECT(depth_only->depthFormat() == PixelFormat::depth32_float);
    }

    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    EXPECT(command_buffer != nil);
    if (command_buffer == nil)
    {
        return;
    }

    MetalRenderPassDesc descriptor;
    descriptor.colors = colorPassDescriptors();
    descriptor.depth = MetalDepthAttachmentDesc{
        AttachmentLoadAction::clear,
        AttachmentStoreAction::store,
        1.0
    };
    descriptor.label = "Firestorm MRT typed pass contract";

    auto wrong_count = descriptor;
    wrong_count.colors.pop_back();
    EXPECT(!beginRenderPass((__bridge void*)command_buffer,
                            *target,
                            wrong_count).has_value());

    auto invalid = descriptor;
    invalid.colors[2].store = static_cast<AttachmentStoreAction>(255);
    EXPECT(!beginRenderPass((__bridge void*)command_buffer,
                            *target,
                            invalid).has_value());

    auto pass = beginRenderPass((__bridge void*)command_buffer,
                                *target,
                                descriptor);
    EXPECT(pass.has_value());
    if (pass)
    {
        EXPECT(pass->end());
    }
    commitAndWait(command_buffer, "MRT pass validation");
}

bool encodeFullscreenDraw(MetalFrameContext& frames,
                          const firestorm::metal::MetalFrameLease& lease,
                          id<MTLRenderCommandEncoder> encoder,
                          float depth)
{
    const auto allocation = frames.allocate(
        lease.token, sizeof(depth), alignof(float));
    EXPECT(allocation.has_value());
    if (!allocation)
    {
        return false;
    }
    std::memcpy(allocation->bytes, &depth, sizeof(depth));
    [encoder setVertexBuffer:(__bridge id<MTLBuffer>)lease.buffer
                      offset:allocation->offset
                     atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:3];
    return true;
}

void validateColorReadback(const MetalTextureReadback& readback,
                           std::size_t index)
{
    EXPECT(index < COLOR_COUNT);
    if (index >= COLOR_COUNT)
    {
        return;
    }
    EXPECT(readback.format == COLOR_FORMATS[index]);
    EXPECT(readback.region.width == 1);
    EXPECT(readback.region.height == 1);
    EXPECT(readback.region.mipLevel == 0);
    EXPECT(readback.region.slice == 0);
    EXPECT(readback.bytesPerRow == READBACK_ROW_BYTES);
    EXPECT(readback.bytesPerImage == READBACK_ROW_BYTES);
    EXPECT(readback.bytes.size() == READBACK_ROW_BYTES);
    if (readback.bytes.size() < 4)
    {
        return;
    }
    for (std::size_t channel = 0; channel < 4; ++channel)
    {
        const auto actual =
            std::to_integer<std::uint8_t>(readback.bytes[channel]);
        if (actual != EXPECTED_COLOR_BYTES[index][channel])
        {
            std::cerr << "FAIL MRT slot=" << index
                      << " raw-channel=" << channel
                      << " expected="
                      << static_cast<unsigned>(
                             EXPECTED_COLOR_BYTES[index][channel])
                      << " actual=" << static_cast<unsigned>(actual)
                      << '\n';
            ++gFailures;
        }
    }
}

void validateDepthReadback(const MetalTextureReadback& readback)
{
    EXPECT(readback.format == PixelFormat::depth32_float);
    EXPECT(readback.region.width == 1);
    EXPECT(readback.region.height == 1);
    EXPECT(readback.bytesPerRow == READBACK_ROW_BYTES);
    EXPECT(readback.bytesPerImage == READBACK_ROW_BYTES);
    EXPECT(readback.bytes.size() == READBACK_ROW_BYTES);
    if (readback.bytes.size() < sizeof(float))
    {
        return;
    }
    float actual = 0.0F;
    std::memcpy(&actual, readback.bytes.data(), sizeof(actual));
    EXPECT(actual == 0.25F);
}

void runGpuOracle(id<MTLDevice> device,
                  id<MTLLibrary> library,
                  id<MTLCommandQueue> queue)
{
    const auto colors = createColors(device, 1, 1);
    const auto depth = createTexture(
        device, PixelFormat::depth32_float, 1, 1,
        "Firestorm exact depth-only target");
    EXPECT(colors.has_value());
    EXPECT(depth.has_value());
    if (!colors || !depth)
    {
        return;
    }

    const auto mrt_target = makeRenderTarget(colorVector(*colors));
    const auto depth_target = makeRenderTarget({}, *depth);
    EXPECT(mrt_target.has_value());
    EXPECT(depth_target.has_value());
    if (!mrt_target || !depth_target)
    {
        return;
    }

    MetalRenderPipelineFamilyCache mrt_cache(
        (__bridge void*)device,
        (__bridge void*)library,
        mrtFamilyDescriptor());
    MetalRenderPipelineFamilyCache depth_pipeline_cache(
        (__bridge void*)device,
        (__bridge void*)library,
        depthFamilyDescriptor());
    EXPECT(mrt_cache.valid());
    EXPECT(depth_pipeline_cache.valid());
    const auto mrt_pipeline = mrt_cache.pipeline(blendDescriptors());
    const auto depth_pipeline = depth_pipeline_cache.pipeline({});
    EXPECT(mrt_pipeline.has_value());
    EXPECT(depth_pipeline.has_value());

    MetalDepthStateCache depth_state_cache((__bridge void*)device);
    EXPECT(depth_state_cache.valid());
    const auto depth_state = depth_state_cache.depthState(
        DepthStateDesc{ CompareFunction::always, true });
    EXPECT(depth_state.has_value());
    if (!mrt_pipeline || !depth_pipeline || !depth_state)
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
    command_buffer.label = @"Firestorm exact MRT and depth-only oracle";

    MetalRenderPassDesc mrt_pass_descriptor;
    mrt_pass_descriptor.colors = colorPassDescriptors();
    mrt_pass_descriptor.label = "Firestorm exact four-color MRT pass";
    auto mrt_pass = beginRenderPass((__bridge void*)command_buffer,
                                    *mrt_target,
                                    mrt_pass_descriptor);
    EXPECT(mrt_pass.has_value());
    if (!mrt_pass)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }
    id<MTLRenderCommandEncoder> mrt_encoder =
        (__bridge id<MTLRenderCommandEncoder>)mrt_pass->encoder();
    [mrt_encoder setRenderPipelineState:
        (__bridge id<MTLRenderPipelineState>)*mrt_pipeline];
    [mrt_encoder setViewport:MTLViewport{ 0.0, 0.0, 1.0, 1.0, 0.0, 1.0 }];
    const bool mrt_encoded = encodeFullscreenDraw(
        frames, *lease, mrt_encoder, 0.0F);
    EXPECT(mrt_pass->end());
    if (!mrt_encoded)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    MetalRenderPassDesc depth_pass_descriptor;
    depth_pass_descriptor.depth = MetalDepthAttachmentDesc{
        AttachmentLoadAction::clear,
        AttachmentStoreAction::store,
        1.0
    };
    depth_pass_descriptor.label = "Firestorm exact depth-only pass";
    auto depth_pass = beginRenderPass((__bridge void*)command_buffer,
                                      *depth_target,
                                      depth_pass_descriptor);
    EXPECT(depth_pass.has_value());
    if (!depth_pass)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }
    id<MTLRenderCommandEncoder> depth_encoder =
        (__bridge id<MTLRenderCommandEncoder>)depth_pass->encoder();
    [depth_encoder setRenderPipelineState:
        (__bridge id<MTLRenderPipelineState>)*depth_pipeline];
    [depth_encoder setDepthStencilState:
        (__bridge id<MTLDepthStencilState>)*depth_state];
    [depth_encoder setViewport:MTLViewport{ 0.0, 0.0, 1.0, 1.0, 0.0, 1.0 }];
    const bool depth_encoded = encodeFullscreenDraw(
        frames, *lease, depth_encoder, 0.25F);
    EXPECT(depth_pass->end());
    if (!depth_encoded)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    std::mutex publication_mutex;
    std::array<std::optional<MetalTextureReadback>, READBACK_COUNT>
        publications;
    std::array<std::uint64_t, READBACK_COUNT> publication_serials{};
    std::vector<std::size_t> publication_order;
    publication_order.reserve(READBACK_COUNT);
    dispatch_semaphore_t published = dispatch_semaphore_create(0);

    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             READBACK_BUDGET);
    EXPECT(batch.valid());
    const MetalTextureRegion region{ 0, 0, 1, 1, 0, 0 };
    for (std::size_t index = 0; index < COLOR_COUNT; ++index)
    {
        const auto status = batch.readbackTexture(
            (*colors)[index],
            region,
            [&, index](std::uint64_t serial, MetalTextureReadback readback) {
                {
                    std::lock_guard<std::mutex> lock(publication_mutex);
                    publication_order.push_back(index);
                    publication_serials[index] = serial;
                    publications[index] = std::move(readback);
                }
                dispatch_semaphore_signal(published);
            });
        EXPECT(status == MetalTransferStatus::encoded);
        if (status != MetalTransferStatus::encoded)
        {
            return;
        }
    }
    const auto depth_status = batch.readbackTexture(
        *depth,
        region,
        [&](std::uint64_t serial, MetalTextureReadback readback) {
            {
                std::lock_guard<std::mutex> lock(publication_mutex);
                publication_order.push_back(COLOR_COUNT);
                publication_serials[COLOR_COUNT] = serial;
                publications[COLOR_COUNT] = std::move(readback);
            }
            dispatch_semaphore_signal(published);
        });
    EXPECT(depth_status == MetalTransferStatus::encoded);
    if (depth_status != MetalTransferStatus::encoded)
    {
        return;
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

    [command_buffer commit];
    for (std::size_t index = 0; index < READBACK_COUNT; ++index)
    {
        requireSignal(published, command_buffer, "MRT/depth readback");
    }
    EXPECT(command_buffer.status == MTLCommandBufferStatusCompleted);
    EXPECT(command_buffer.error == nil);

    std::lock_guard<std::mutex> lock(publication_mutex);
    EXPECT(publication_order ==
           std::vector<std::size_t>({ 0, 1, 2, 3, 4 }));
    for (std::size_t index = 0; index < READBACK_COUNT; ++index)
    {
        EXPECT(publications[index].has_value());
        EXPECT(publication_serials[index] == *submission_serial);
    }
    for (std::size_t index = 0; index < COLOR_COUNT; ++index)
    {
        if (publications[index])
        {
            validateColorReadback(*publications[index], index);
        }
    }
    if (publications[COLOR_COUNT])
    {
        validateDepthReadback(*publications[COLOR_COUNT]);
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
        id<MTLLibrary> library = loadLibrary(device, metallib_path);
        EXPECT(queue != nil);
        if (queue != nil)
        {
            testTargetAndPassContract(device, queue);
        }
        if (queue != nil && library != nil)
        {
            testPipelineContract(device, library);
            runGpuOracle(device, library, queue);
        }
    }

    if (gFailures != 0)
    {
        std::cerr << gFailures << " Metal MRT test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "PASS typed four-color MRT and exact depth-only pass\n";
    return EXIT_SUCCESS;
}
