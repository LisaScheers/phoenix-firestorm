/**
 * @file render-pass-test-objc.mm
 * @brief Typed target, attachment, and cross-pass load/store validation.
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
#include <cstring>
#include <iostream>
#include <limits>
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

using firestorm::metal::AttachmentLoadAction;
using firestorm::metal::AttachmentStoreAction;
using firestorm::metal::BlendAttachmentDesc;
using firestorm::metal::CompareFunction;
using firestorm::metal::DepthStateDesc;
using firestorm::metal::MetalClearColor;
using firestorm::metal::MetalColorAttachmentDesc;
using firestorm::metal::MetalDepthAttachmentDesc;
using firestorm::metal::MetalDepthStateCache;
using firestorm::metal::MetalFrameContext;
using firestorm::metal::MetalFrameLease;
using firestorm::metal::MetalPrivateTexture2D;
using firestorm::metal::MetalRenderPass;
using firestorm::metal::MetalRenderPassDesc;
using firestorm::metal::MetalRenderPipelineFamilyCache;
using firestorm::metal::MetalRenderPipelineFamilyDesc;
using firestorm::metal::MetalRenderPipelineHandle;
using firestorm::metal::MetalRenderTarget;
using firestorm::metal::MetalTexture2DDescriptor;
using firestorm::metal::MetalTextureReadback;
using firestorm::metal::MetalTextureRegion;
using firestorm::metal::MetalTextureUsage;
using firestorm::metal::MetalTransferBatch;
using firestorm::metal::MetalTransferStatus;
using firestorm::metal::PixelFormat;
using firestorm::metal::beginRenderPass;
using firestorm::metal::createPrivateTexture2D;
using firestorm::metal::makeRenderTarget;

constexpr std::uint32_t WIDTH  = 2;
constexpr std::uint32_t HEIGHT = 1;
constexpr std::size_t ACTIVE_ROW_BYTES = 8;
constexpr std::size_t READBACK_BYTES_PER_ROW = 256;
constexpr const char* PIPELINE_LABEL =
    "Firestorm 2x1 render-pass load/store oracle";
constexpr const char* VERTEX_FUNCTION =
    "firestorm_render_pass_vertex";
constexpr const char* FRAGMENT_FUNCTION =
    "firestorm_render_pass_fragment";

constexpr std::array<std::uint8_t, ACTIVE_ROW_BYTES> EXPECTED_PIXELS{
    0, 255, 0, 255,
    255, 0, 0, 255,
};

struct alignas(16) RenderPassDraw
{
    float depth;
    float unused[3];
};

static_assert(sizeof(RenderPassDraw) == 16,
              "Render-pass draw bytes must match the Metal constant");

struct TargetResources
{
    MetalPrivateTexture2D color;
    MetalPrivateTexture2D depth;
    MetalRenderTarget target;
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
        std::cerr << "FAIL load render-pass metallib: "
                  << toString(error.localizedDescription) << '\n';
        ++gFailures;
    }
    return library;
}

std::optional<MetalPrivateTexture2D>
createTexture(id<MTLDevice> device,
              PixelFormat format,
              std::uint32_t width,
              std::uint32_t height,
              std::uint32_t mip_levels,
              MetalTextureUsage usage,
              const std::string& label)
{
    MetalTexture2DDescriptor descriptor;
    descriptor.format = format;
    descriptor.width = width;
    descriptor.height = height;
    descriptor.mipLevels = mip_levels;
    descriptor.usage = usage;
    descriptor.label = label;
    return createPrivateTexture2D((__bridge void*)device, descriptor);
}

std::optional<TargetResources> createTarget(id<MTLDevice> device)
{
    const auto color = createTexture(device,
                                     PixelFormat::rgba8_unorm,
                                     WIDTH,
                                     HEIGHT,
                                     1,
                                     MetalTextureUsage::render_target,
                                     "Firestorm render-pass 2x1 color");
    const auto depth = createTexture(device,
                                     PixelFormat::depth32_float,
                                     WIDTH,
                                     HEIGHT,
                                     1,
                                     MetalTextureUsage::render_target,
                                     "Firestorm render-pass 2x1 depth");
    if (!color || !depth)
    {
        return std::nullopt;
    }

    const auto target = makeRenderTarget(*color, *depth);
    if (!target)
    {
        return std::nullopt;
    }
    return TargetResources{ *color, *depth, *target };
}

MetalRenderPassDesc passDescriptor(AttachmentLoadAction color_load,
                                   AttachmentStoreAction color_store,
                                   AttachmentLoadAction depth_load,
                                   AttachmentStoreAction depth_store)
{
    MetalRenderPassDesc descriptor;
    descriptor.color.load = color_load;
    descriptor.color.store = color_store;
    descriptor.color.clear = MetalClearColor{ 0.0, 0.0, 0.0, 1.0 };
    descriptor.depth = MetalDepthAttachmentDesc{
        depth_load, depth_store, 1.0
    };
    descriptor.label = "Firestorm typed render-pass contract";
    return descriptor;
}

void testTargetContract(id<MTLDevice> device)
{
    MetalRenderTarget empty;
    EXPECT(!empty.valid());
    EXPECT(empty.width() == 0);
    EXPECT(empty.height() == 0);
    EXPECT(empty.sampleCount() == 0);
    EXPECT(!empty.depthFormat().has_value());
    EXPECT(!empty.colorTexture().valid());
    EXPECT(!empty.depthTexture().has_value());
    EXPECT(!makeRenderTarget(MetalPrivateTexture2D{}).has_value());

    const auto color = createTexture(device,
                                     PixelFormat::rgba8_unorm,
                                     WIDTH,
                                     HEIGHT,
                                     1,
                                     MetalTextureUsage::render_target,
                                     "Firestorm target contract color");
    const auto depth = createTexture(device,
                                     PixelFormat::depth32_float,
                                     WIDTH,
                                     HEIGHT,
                                     1,
                                     MetalTextureUsage::render_target,
                                     "Firestorm target contract depth");
    EXPECT(color.has_value());
    EXPECT(depth.has_value());
    if (!color || !depth)
    {
        return;
    }

    const auto target = makeRenderTarget(*color, *depth);
    EXPECT(target.has_value());
    if (target)
    {
        EXPECT(target->valid());
        EXPECT(target->width() == WIDTH);
        EXPECT(target->height() == HEIGHT);
        EXPECT(target->sampleCount() == 1);
        EXPECT(target->colorFormat() == PixelFormat::rgba8_unorm);
        EXPECT(target->depthFormat() == PixelFormat::depth32_float);
        EXPECT(target->colorTexture().nativeHandle() == color->nativeHandle());
        EXPECT(target->depthTexture().has_value());
        if (target->depthTexture())
        {
            EXPECT(target->depthTexture()->nativeHandle() ==
                   depth->nativeHandle());
        }
    }

    const auto shader_only_color = createTexture(
        device,
        PixelFormat::rgba8_unorm,
        WIDTH,
        HEIGHT,
        1,
        MetalTextureUsage::shader_read,
        "Firestorm invalid non-target color");
    EXPECT(shader_only_color.has_value());
    if (shader_only_color)
    {
        EXPECT(!makeRenderTarget(*shader_only_color).has_value());
    }

    EXPECT(!makeRenderTarget(*depth).has_value());
    EXPECT(!makeRenderTarget(*color, *color).has_value());

    const auto mismatched_depth = createTexture(
        device,
        PixelFormat::depth32_float,
        1,
        HEIGHT,
        1,
        MetalTextureUsage::render_target,
        "Firestorm invalid mismatched depth");
    EXPECT(mismatched_depth.has_value());
    if (mismatched_depth)
    {
        EXPECT(!makeRenderTarget(*color, *mismatched_depth).has_value());
    }

    const auto shader_only_depth = createTexture(
        device,
        PixelFormat::depth32_float,
        WIDTH,
        HEIGHT,
        1,
        MetalTextureUsage::shader_read,
        "Firestorm invalid non-target depth");
    EXPECT(shader_only_depth.has_value());
    if (shader_only_depth)
    {
        EXPECT(!makeRenderTarget(*color, *shader_only_depth).has_value());
    }

    const auto mipmapped_color = createTexture(
        device,
        PixelFormat::rgba8_unorm,
        WIDTH,
        HEIGHT,
        2,
        MetalTextureUsage::render_target,
        "Firestorm deferred mip attachment");
    EXPECT(mipmapped_color.has_value());
    if (mipmapped_color)
    {
        EXPECT(!makeRenderTarget(*mipmapped_color).has_value());
    }

    for (id<MTLDevice> other_device in MTLCopyAllDevices())
    {
        if (other_device == device)
        {
            continue;
        }
        const auto other_depth = createTexture(
            other_device,
            PixelFormat::depth32_float,
            WIDTH,
            HEIGHT,
            1,
            MetalTextureUsage::render_target,
            "Firestorm wrong-device depth");
        EXPECT(other_depth.has_value());
        if (other_depth)
        {
            EXPECT(!makeRenderTarget(*color, *other_depth).has_value());
        }
    }
}

void testPassContract(id<MTLDevice> device,
                      id<MTLCommandQueue> queue)
{
    const auto resources = createTarget(device);
    EXPECT(resources.has_value());
    if (!resources)
    {
        return;
    }

    MetalRenderPassDesc descriptor = passDescriptor(
        AttachmentLoadAction::dont_care,
        AttachmentStoreAction::dont_care,
        AttachmentLoadAction::dont_care,
        AttachmentStoreAction::dont_care);

    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    EXPECT(command_buffer != nil);
    if (command_buffer == nil)
    {
        return;
    }

    EXPECT(!beginRenderPass(nullptr, resources->target, descriptor).has_value());
    EXPECT(!beginRenderPass((__bridge void*)device,
                            resources->target,
                            descriptor).has_value());
    EXPECT(!beginRenderPass((__bridge void*)command_buffer,
                            MetalRenderTarget{},
                            descriptor).has_value());

    auto invalid = descriptor;
    invalid.depth.reset();
    EXPECT(!beginRenderPass((__bridge void*)command_buffer,
                            resources->target,
                            invalid).has_value());

    const auto color_only = makeRenderTarget(resources->color);
    EXPECT(color_only.has_value());
    if (color_only)
    {
        EXPECT(!beginRenderPass((__bridge void*)command_buffer,
                                *color_only,
                                descriptor).has_value());
    }

    invalid = descriptor;
    invalid.color.load = static_cast<AttachmentLoadAction>(255);
    EXPECT(!beginRenderPass((__bridge void*)command_buffer,
                            resources->target,
                            invalid).has_value());
    invalid = descriptor;
    invalid.color.store = static_cast<AttachmentStoreAction>(255);
    EXPECT(!beginRenderPass((__bridge void*)command_buffer,
                            resources->target,
                            invalid).has_value());
    invalid = descriptor;
    invalid.depth->load = static_cast<AttachmentLoadAction>(255);
    EXPECT(!beginRenderPass((__bridge void*)command_buffer,
                            resources->target,
                            invalid).has_value());
    invalid = descriptor;
    invalid.depth->store = static_cast<AttachmentStoreAction>(255);
    EXPECT(!beginRenderPass((__bridge void*)command_buffer,
                            resources->target,
                            invalid).has_value());

    invalid = descriptor;
    invalid.label = std::string("\xff", 1);
    EXPECT(!beginRenderPass((__bridge void*)command_buffer,
                            resources->target,
                            invalid).has_value());

    const double nan = std::numeric_limits<double>::quiet_NaN();
    const double infinity = std::numeric_limits<double>::infinity();
    invalid = descriptor;
    invalid.color.load = AttachmentLoadAction::clear;
    invalid.color.clear.red = nan;
    EXPECT(!beginRenderPass((__bridge void*)command_buffer,
                            resources->target,
                            invalid).has_value());
    invalid.color.clear.red = infinity;
    EXPECT(!beginRenderPass((__bridge void*)command_buffer,
                            resources->target,
                            invalid).has_value());

    invalid = descriptor;
    invalid.depth->load = AttachmentLoadAction::clear;
    invalid.depth->clear = nan;
    EXPECT(!beginRenderPass((__bridge void*)command_buffer,
                            resources->target,
                            invalid).has_value());
    invalid.depth->clear = -0.01;
    EXPECT(!beginRenderPass((__bridge void*)command_buffer,
                            resources->target,
                            invalid).has_value());
    invalid.depth->clear = 1.01;
    EXPECT(!beginRenderPass((__bridge void*)command_buffer,
                            resources->target,
                            invalid).has_value());

    auto ignored_clear = descriptor;
    ignored_clear.color.clear = MetalClearColor{ nan, infinity, -infinity, nan };
    ignored_clear.depth->clear = nan;
    auto ignored_pass = beginRenderPass((__bridge void*)command_buffer,
                                        resources->target,
                                        ignored_clear);
    EXPECT(ignored_pass.has_value());
    if (ignored_pass)
    {
        EXPECT(ignored_pass->end());
    }

    auto hdr_clear = descriptor;
    hdr_clear.color.load = AttachmentLoadAction::clear;
    hdr_clear.color.clear = MetalClearColor{ -2.0, 3.0, 100.0, 1.0 };
    auto hdr_pass = beginRenderPass((__bridge void*)command_buffer,
                                    resources->target,
                                    hdr_clear);
    EXPECT(hdr_pass.has_value());
    if (hdr_pass)
    {
        EXPECT(hdr_pass->end());
    }

    auto movable_pass = beginRenderPass((__bridge void*)command_buffer,
                                        resources->target,
                                        descriptor);
    EXPECT(movable_pass.has_value());
    if (movable_pass)
    {
        MetalRenderPass moved(std::move(*movable_pass));
        EXPECT(!movable_pass->active());
        EXPECT(moved.active());
        EXPECT(moved.encoder() != nullptr);
        EXPECT(moved.end());
        EXPECT(!moved.active());
        EXPECT(moved.encoder() == nullptr);
        EXPECT(!moved.end());
    }

    {
        auto destructor_pass = beginRenderPass(
            (__bridge void*)command_buffer,
            resources->target,
            descriptor);
        EXPECT(destructor_pass.has_value());
        EXPECT(destructor_pass && destructor_pass->active());
    }
    auto after_destructor = beginRenderPass((__bridge void*)command_buffer,
                                            resources->target,
                                            descriptor);
    EXPECT(after_destructor.has_value());
    if (after_destructor)
    {
        EXPECT(after_destructor->end());
    }

    commitAndWait(command_buffer, "render-pass contract command buffer");

    id<MTLCommandBuffer> enqueued = [queue commandBuffer];
    EXPECT(enqueued != nil);
    if (enqueued != nil)
    {
        [enqueued enqueue];
        EXPECT(enqueued.status == MTLCommandBufferStatusEnqueued);
        auto enqueued_pass = beginRenderPass((__bridge void*)enqueued,
                                             resources->target,
                                             descriptor);
        EXPECT(enqueued_pass.has_value());
        if (enqueued_pass)
        {
            EXPECT(enqueued_pass->end());
        }
        commitAndWait(enqueued, "enqueued render-pass command buffer");
    }

    id<MTLCommandBuffer> committed = [queue commandBuffer];
    EXPECT(committed != nil);
    if (committed != nil)
    {
        commitAndWait(committed, "precommitted render-pass rejection");
        EXPECT(!beginRenderPass((__bridge void*)committed,
                                resources->target,
                                descriptor).has_value());
    }

    id<MTLCommandBuffer> first_command = [queue commandBuffer];
    id<MTLCommandBuffer> second_command = [queue commandBuffer];
    EXPECT(first_command != nil);
    EXPECT(second_command != nil);
    if (first_command != nil && second_command != nil)
    {
        auto first_pass = beginRenderPass((__bridge void*)first_command,
                                          resources->target,
                                          descriptor);
        auto second_pass = beginRenderPass((__bridge void*)second_command,
                                           resources->target,
                                           descriptor);
        EXPECT(first_pass.has_value());
        EXPECT(second_pass.has_value());
        if (first_pass && second_pass)
        {
            MetalRenderPass destination(std::move(*first_pass));
            MetalRenderPass source(std::move(*second_pass));
            destination = std::move(source);
            EXPECT(!source.active());
            EXPECT(destination.active());

            auto first_followup = beginRenderPass(
                (__bridge void*)first_command,
                resources->target,
                descriptor);
            EXPECT(first_followup.has_value());
            if (first_followup)
            {
                EXPECT(first_followup->end());
            }
            EXPECT(destination.end());
        }
        commitAndWait(first_command, "move-assignment destination command");
        commitAndWait(second_command, "move-assignment source command");
    }

    for (id<MTLDevice> other_device in MTLCopyAllDevices())
    {
        if (other_device == device)
        {
            continue;
        }
        id<MTLCommandQueue> other_queue = [other_device newCommandQueue];
        id<MTLCommandBuffer> other_command = [other_queue commandBuffer];
        EXPECT(other_command != nil);
        if (other_command != nil)
        {
            EXPECT(!beginRenderPass((__bridge void*)other_command,
                                    resources->target,
                                    descriptor).has_value());
        }
    }
}

MetalRenderPipelineFamilyDesc pipelineFamilyDescriptor()
{
    MetalRenderPipelineFamilyDesc descriptor;
    descriptor.vertexFunction = VERTEX_FUNCTION;
    descriptor.fragmentFunction = FRAGMENT_FUNCTION;
    descriptor.colorFormat = PixelFormat::rgba8_unorm;
    descriptor.depthFormat = PixelFormat::depth32_float;
    return descriptor;
}

bool encodeDraw(MetalFrameContext& frames,
                const MetalFrameLease& lease,
                id<MTLRenderCommandEncoder> encoder,
                float depth)
{
    const RenderPassDraw draw{ depth, { 0.0F, 0.0F, 0.0F } };
    const auto allocation = frames.allocate(lease.token,
                                            sizeof(draw),
                                            alignof(RenderPassDraw));
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

void validateReadback(const MetalTextureReadback& readback)
{
    EXPECT(readback.format == PixelFormat::rgba8_unorm);
    EXPECT(readback.region.x == 0);
    EXPECT(readback.region.y == 0);
    EXPECT(readback.region.width == WIDTH);
    EXPECT(readback.region.height == HEIGHT);
    EXPECT(readback.region.mipLevel == 0);
    EXPECT(readback.region.slice == 0);
    EXPECT(readback.bytesPerRow == READBACK_BYTES_PER_ROW);
    EXPECT(readback.bytesPerImage == READBACK_BYTES_PER_ROW);
    EXPECT(readback.bytes.size() == READBACK_BYTES_PER_ROW);
    if (readback.bytes.size() < ACTIVE_ROW_BYTES)
    {
        return;
    }

    constexpr const char* channels[] = { "R", "G", "B", "A" };
    for (std::size_t offset = 0; offset < ACTIVE_ROW_BYTES; ++offset)
    {
        const std::uint8_t actual =
            std::to_integer<std::uint8_t>(readback.bytes[offset]);
        if (actual != EXPECTED_PIXELS[offset])
        {
            std::cerr << "FAIL pipeline=\"" << PIPELINE_LABEL
                      << "\" pixel=" << offset / 4
                      << " channel=" << channels[offset % 4]
                      << " expected="
                      << static_cast<unsigned>(EXPECTED_PIXELS[offset])
                      << " actual=" << static_cast<unsigned>(actual) << '\n';
            ++gFailures;
            break;
        }
    }
}

void runGpuOracle(id<MTLDevice> device,
                  id<MTLLibrary> library,
                  id<MTLCommandQueue> queue)
{
    const auto resources = createTarget(device);
    EXPECT(resources.has_value());
    if (!resources)
    {
        return;
    }

    MetalRenderPipelineFamilyCache pipeline_cache(
        (__bridge void*)device,
        (__bridge void*)library,
        pipelineFamilyDescriptor());
    EXPECT(pipeline_cache.valid());
    const auto pipeline = pipeline_cache.pipeline(BlendAttachmentDesc{});
    EXPECT(pipeline.has_value());

    MetalDepthStateCache depth_cache((__bridge void*)device);
    EXPECT(depth_cache.valid());
    const auto depth_state = depth_cache.depthState(
        DepthStateDesc{ CompareFunction::less, false });
    EXPECT(depth_state.has_value());
    if (!pipeline || !depth_state)
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
    command_buffer.label = @"Firestorm exact render-pass validation";

    auto clear_pass_descriptor = passDescriptor(
        AttachmentLoadAction::clear,
        AttachmentStoreAction::store,
        AttachmentLoadAction::clear,
        AttachmentStoreAction::store);
    clear_pass_descriptor.color.clear = MetalClearColor{ 1.0, 0.0, 0.0, 1.0 };
    clear_pass_descriptor.depth->clear = 0.5;
    clear_pass_descriptor.label = "Firestorm clear/store attachments";
    auto clear_pass = beginRenderPass((__bridge void*)command_buffer,
                                      resources->target,
                                      clear_pass_descriptor);
    EXPECT(clear_pass.has_value());
    if (!clear_pass || !clear_pass->end())
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    auto load_pass_descriptor = passDescriptor(
        AttachmentLoadAction::load,
        AttachmentStoreAction::store,
        AttachmentLoadAction::load,
        AttachmentStoreAction::dont_care);
    load_pass_descriptor.label = PIPELINE_LABEL;
    auto load_pass = beginRenderPass((__bridge void*)command_buffer,
                                     resources->target,
                                     load_pass_descriptor);
    EXPECT(load_pass.has_value());
    if (!load_pass)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    id<MTLRenderCommandEncoder> encoder =
        (__bridge id<MTLRenderCommandEncoder>)load_pass->encoder();
    EXPECT(encoder != nil);
    [encoder setRenderPipelineState:
        (__bridge id<MTLRenderPipelineState>)*pipeline];
    [encoder setDepthStencilState:
        (__bridge id<MTLDepthStencilState>)*depth_state];
    [encoder setViewport:MTLViewport{ 0.0, 0.0,
                                     static_cast<double>(WIDTH),
                                     static_cast<double>(HEIGHT),
                                     0.0, 1.0 }];

    [encoder setScissorRect:MTLScissorRect{ 0, 0, 1, 1 }];
    bool encoded = encodeDraw(frames, *lease, encoder, 0.25F);
    [encoder setScissorRect:MTLScissorRect{ 1, 0, 1, 1 }];
    encoded = encodeDraw(frames, *lease, encoder, 0.75F) && encoded;
    EXPECT(load_pass->end());
    if (!encoded)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    EXPECT(frames.retire(lease->token,
                         resources->depth.nativeHandle()));

    std::mutex publication_mutex;
    std::optional<MetalTextureReadback> publication;
    std::uint64_t published_serial = 0;
    dispatch_semaphore_t published = dispatch_semaphore_create(0);

    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             READBACK_BYTES_PER_ROW);
    EXPECT(batch.valid());
    const MetalTextureRegion region{ 0, 0, WIDTH, HEIGHT, 0, 0 };
    const auto readback_status = batch.readbackTexture2D(
        resources->color,
        region,
        [&](std::uint64_t serial, MetalTextureReadback readback) {
            {
                std::lock_guard<std::mutex> lock(publication_mutex);
                published_serial = serial;
                publication = std::move(readback);
            }
            dispatch_semaphore_signal(published);
        });
    EXPECT(readback_status == MetalTransferStatus::encoded);
    if (readback_status != MetalTransferStatus::encoded)
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

    {
        std::lock_guard<std::mutex> lock(publication_mutex);
        EXPECT(!publication.has_value());
    }
    [command_buffer commit];
    requireSignal(published, command_buffer, "render-pass readback publication");
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
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        EXPECT(device != nil);
        if (device == nil)
        {
            return EXIT_FAILURE;
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];
        EXPECT(queue != nil);
        id<MTLLibrary> library = loadLibrary(device, metallib_path);
        if (queue != nil)
        {
            testTargetContract(device);
            testPassContract(device, queue);
        }
        if (queue != nil && library != nil)
        {
            runGpuOracle(device, library, queue);
        }
    }

    if (gFailures != 0)
    {
        std::cerr << gFailures << " Metal render-pass test(s) failed\n";
        return EXIT_FAILURE;
    }

    std::cout << "PASS typed Metal targets and exact cross-pass load/store\n";
    return EXIT_SUCCESS;
}
