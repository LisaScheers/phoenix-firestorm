/**
 * @file llmetalbootstrap-objc.mm
 * @brief Native CAMetalLayer implementation of the Metal bootstrap.
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

#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "llmetalbootstrap.h"
#include "llmetalframecontext.h"
#if defined(LL_ACTIVE_METAL_VIEWER)
#include "llmetalgeometry.h"
#include "llmetalpipeline.h"
#include "llmetalprogram.h"
#include "llmetalsampler.h"
#include "llmetaltransfer.h"
#endif

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <condition_variable>
#include <cstring>
#include <functional>
#include <iomanip>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <utility>
#include <vector>

#if defined(LL_ACTIVE_METAL_VIEWER)
extern "C" void reportActiveMetalBootstrapTerminalFailure(const char* message);
#endif

namespace firestorm::metal
{
namespace
{

constexpr std::uint32_t MAX_IN_FLIGHT_FRAMES =
    static_cast<std::uint32_t>(MetalFrameContext::kContextCount);

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
        return "unknown Metal error";
    }

    std::ostringstream message;
    message << toString(error.localizedDescription)
            << " (" << toString(error.domain) << ' ' << error.code << ')';
    return message.str();
}

void assignError(std::string* destination, std::string message)
{
    if (destination)
    {
        *destination = std::move(message);
    }
}

struct CompletionState
{
    std::atomic<std::uint64_t> submitted{0};
    std::atomic<std::uint64_t> completed{0};
    std::atomic<std::uint64_t> presented{0};
    std::mutex mutex;
    std::condition_variable condition;
    std::uint64_t last_error_submission = 0;
    std::uint64_t reported_through = 0;
    std::string last_error;
    std::function<void()> frame_slot_available;
#if defined(LL_ACTIVE_METAL_VIEWER)
    bool terminal_failure_published = false;
    bool terminal_failure_delivered = false;
    std::string terminal_failure_message;
    std::function<void(std::string)> terminal_failure_handler;
#endif
};

void notifyFrameSlotAvailable(const std::shared_ptr<CompletionState>& state)
{
    std::function<void()> handler;
    {
        std::lock_guard lock(state->mutex);
        handler = state->frame_slot_available;
    }
    if (handler)
    {
        handler();
    }
}

#if defined(LL_ACTIVE_METAL_VIEWER)
void publishTerminalFailureOnce(
    const std::shared_ptr<CompletionState>& state,
    std::string message)
{
    if (message.empty())
    {
        message = "unknown terminal Metal bootstrap failure";
    }

    std::function<void(std::string)> handler;
    std::string delivered_message;
    {
        std::lock_guard lock(state->mutex);
        if (state->terminal_failure_published)
        {
            return;
        }

        state->terminal_failure_published = true;
        state->terminal_failure_message = std::move(message);
        if (state->terminal_failure_handler)
        {
            state->terminal_failure_delivered = true;
            handler = state->terminal_failure_handler;
            delivered_message = state->terminal_failure_message;
        }
    }

    if (handler)
    {
        handler(std::move(delivered_message));
    }
}

enum class ArtifactPreparationPhase
{
    preparing,
    uploaded,
    ready,
    failed,
};

const char* toString(ArtifactPreparationPhase phase) noexcept
{
    switch (phase)
    {
        case ArtifactPreparationPhase::preparing:
            return "preparing";
        case ArtifactPreparationPhase::uploaded:
            return "uploaded";
        case ArtifactPreparationPhase::ready:
            return "ready";
        case ArtifactPreparationPhase::failed:
            return "failed";
    }
    return "unknown";
}

struct ArtifactPreparationState
{
    std::mutex mutex;
    ArtifactPreparationPhase phase = ArtifactPreparationPhase::preparing;
    std::optional<MetalPrivateBuffer> positions;
    std::optional<MetalPrivateTexture> texture;
    std::string error;
};

bool isPresentationCopyProgram(const MetalProgramDescriptor& program,
                               std::string& error)
{
    if (program.name != "presentation_copy" ||
        program.colorFormats.size() != 1 ||
        program.colorFormats[0] != PixelFormat::bgra8_unorm ||
        program.depthFormat.has_value() || program.sampleCount != 1)
    {
        error = "presentation_copy has an incompatible attachment contract";
        return false;
    }
    if (program.vertexAttributes.size() != 1 ||
        program.vertexLayouts.size() != 1)
    {
        error = "presentation_copy must declare exactly one vertex stream";
        return false;
    }

    const MetalVertexAttributeDescriptor& attribute =
        program.vertexAttributes[0];
    const MetalVertexBufferLayoutDescriptor& layout = program.vertexLayouts[0];
    if (attribute.name != "position" ||
        attribute.format != MetalVertexFormat::float32x3 ||
        attribute.bufferIndex != layout.bufferIndex ||
        layout.stepFunction != MetalVertexStepFunction::per_vertex ||
        static_cast<std::size_t>(attribute.offset) + sizeof(float) * 3U >
            layout.stride)
    {
        error = "presentation_copy has an incompatible position stream";
        return false;
    }
    if (!program.vertexBindings.buffers.empty() ||
        !program.vertexBindings.textures.empty() ||
        !program.vertexBindings.samplers.empty() ||
        !program.fragmentBindings.buffers.empty() ||
        program.fragmentBindings.textures.size() != 1 ||
        program.fragmentBindings.samplers.size() != 1)
    {
        error = "presentation_copy has unexpected stage resources";
        return false;
    }

    const MetalTextureBindingDescriptor& texture =
        program.fragmentBindings.textures[0];
    const MetalSamplerBindingDescriptor& sampler =
        program.fragmentBindings.samplers[0];
    if (texture.name != "diffuseMap" || sampler.name != "diffuseMap" ||
        texture.type != MetalTextureType::texture_2d ||
        texture.dataType != MetalTextureDataType::float32 ||
        texture.arrayLength != 1 || texture.depth)
    {
        error = "presentation_copy has an incompatible sampled texture";
        return false;
    }
    return true;
}
#endif

class MetalRenderer final
{
public:
    static std::shared_ptr<MetalRenderer> create(
        const std::string& metallib_path,
        std::string& error)
    {
        auto renderer = std::shared_ptr<MetalRenderer>(new MetalRenderer());
        if (!renderer->initialize(metallib_path, error))
        {
            return {};
        }

#if defined(LL_ACTIVE_METAL_VIEWER)
        if (!renderer->beginArtifactPreparation(error))
        {
            return {};
        }
#endif

        return renderer;
    }

    id<MTLDevice> device() const noexcept
    {
        return mDevice;
    }

    MTLPixelFormat pixelFormat() const noexcept
    {
        return MTLPixelFormatBGRA8Unorm;
    }

    void setFrameSlotAvailableHandler(std::function<void()> handler)
    {
        std::lock_guard lock(mCompletionState->mutex);
        mCompletionState->frame_slot_available = std::move(handler);
    }

#if defined(LL_ACTIVE_METAL_VIEWER)
    void setTerminalFailureHandler(std::function<void(std::string)> handler)
    {
        std::function<void(std::string)> delivery;
        std::string message;
        {
            std::lock_guard lock(mCompletionState->mutex);
            mCompletionState->terminal_failure_handler = std::move(handler);
            if (mCompletionState->terminal_failure_published &&
                !mCompletionState->terminal_failure_delivered &&
                mCompletionState->terminal_failure_handler)
            {
                mCompletionState->terminal_failure_delivered = true;
                delivery = mCompletionState->terminal_failure_handler;
                message = mCompletionState->terminal_failure_message;
            }
        }

        if (delivery)
        {
            delivery(std::move(message));
        }
    }

    void reportTerminalFailure(std::string message)
    {
        publishTerminalFailureOnce(mCompletionState, std::move(message));
    }
#endif

    FrameSubmission render(CAMetalLayer* layer, std::string* error) noexcept
    {
        assignError(error, {});

        if (![NSThread isMainThread])
        {
            assignError(error, "Metal frames must be submitted on the AppKit main thread");
            return FrameSubmission::failed;
        }

#if defined(LL_ACTIVE_METAL_VIEWER)
        const FrameSubmission preparation = prepareArtifactForRender(error);
        if (preparation != FrameSubmission::submitted)
        {
            return preparation;
        }
#endif

        if (!layer || layer.drawableSize.width < 1.0 || layer.drawableSize.height < 1.0)
        {
            return FrameSubmission::drawable_unavailable;
        }

        const auto frame = mRenderFrames->tryBegin();
        if (!frame)
        {
            return FrameSubmission::renderer_busy;
        }

        id<MTLCommandBuffer> command_buffer = [mCommandQueue commandBuffer];
        if (!command_buffer)
        {
            mRenderFrames->cancel(frame->token);
            assignError(error, "Metal failed to create a command buffer");
            return FrameSubmission::failed;
        }

        command_buffer.label = @"Firestorm Metal bootstrap frame";

        // Keep drawable acquisition after CPU-side setup and in-flight gating.
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (!drawable)
        {
            mRenderFrames->cancel(frame->token);
            return FrameSubmission::drawable_unavailable;
        }

        MTLRenderPassDescriptor* render_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        render_pass.colorAttachments[0].texture = drawable.texture;
        render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        render_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

        id<MTLRenderCommandEncoder> encoder =
            [command_buffer renderCommandEncoderWithDescriptor:render_pass];
        if (!encoder)
        {
            mRenderFrames->cancel(frame->token);
            assignError(error, "Metal failed to create a render command encoder");
            return FrameSubmission::failed;
        }

        encoder.label = @"Firestorm bootstrap clear and triangle";
#if defined(LL_ACTIVE_METAL_VIEWER)
        [encoder setFragmentTexture:
            (__bridge id<MTLTexture>)mArtifactTexture->nativeHandle()
                            atIndex:mTextureIndex];
        [encoder setFragmentSamplerState:
            (__bridge id<MTLSamplerState>)mSampler
                                 atIndex:mSamplerIndex];
        const MetalDrawStatus draw_status = encodeArtifactTriangles(
            (__bridge void*)encoder,
            *mArtifactPipeline,
            *mArtifactGeometry,
            0,
            3);
        if (draw_status != MetalDrawStatus::encoded)
        {
            [encoder endEncoding];
            mRenderFrames->cancel(frame->token);
            assignError(error, "artifact geometry rejected the presentation_copy draw");
            return FrameSubmission::failed;
        }
#else
        [encoder setRenderPipelineState:mPipeline];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
#endif
        [encoder endEncoding];

        const auto presentation_state = mCompletionState;
        [drawable addPresentedHandler:^(id<MTLDrawable> presented_drawable) {
            (void)presented_drawable;
            {
                std::lock_guard lock(presentation_state->mutex);
                presentation_state->presented.fetch_add(1, std::memory_order_release);
            }
            presentation_state->condition.notify_all();
        }];
        [command_buffer presentDrawable:drawable];

        const auto completion_state = mCompletionState;
        const auto frame_serial = mRenderFrames->submit(
            frame->token,
            (__bridge void*)command_buffer,
            [completion_state](std::uint64_t) {
                notifyFrameSlotAvailable(completion_state);
            });
        if (!frame_serial)
        {
            mRenderFrames->cancel(frame->token);
            assignError(error, "Metal frame context rejected the presentation submission");
            return FrameSubmission::failed;
        }

        const std::uint64_t submission =
            mCompletionState->submitted.fetch_add(1, std::memory_order_release) + 1;
        [command_buffer addCompletedHandler:^(id<MTLCommandBuffer> completed_buffer) {
            @autoreleasepool
            {
                std::string completion_error;
                const bool command_failed =
                    completed_buffer.status == MTLCommandBufferStatusError;
                if (command_failed)
                {
                    completion_error = toString(completed_buffer.error);
                }

                {
                    std::lock_guard lock(completion_state->mutex);
                    if (!completion_error.empty())
                    {
                        if (submission >= completion_state->last_error_submission)
                        {
                            completion_state->last_error_submission = submission;
                            completion_state->last_error = completion_error;
                        }
                    }
                    completion_state->completed.fetch_add(1, std::memory_order_release);
                }

                completion_state->condition.notify_all();
                if (command_failed)
                {
#if defined(LL_ACTIVE_METAL_VIEWER)
                    publishTerminalFailureOnce(
                        completion_state, std::move(completion_error));
#endif
                    notifyFrameSlotAvailable(completion_state);
                }
            }
        }];

        [command_buffer commit];
        return FrameSubmission::submitted;
    }

    bool waitForIdle(std::chrono::milliseconds timeout, std::string* error) noexcept
    {
        assignError(error, {});

        const std::uint64_t target =
            mCompletionState->submitted.load(std::memory_order_acquire);
        std::unique_lock lock(mCompletionState->mutex);
        const bool finished = mCompletionState->condition.wait_for(
            lock,
            timeout,
            [this, target] {
                return mCompletionState->completed.load(std::memory_order_acquire) >= target;
            });

        if (!finished)
        {
            assignError(error, "timed out waiting for Metal command completion");
            return false;
        }

        if (mCompletionState->last_error_submission >
                mCompletionState->reported_through &&
            mCompletionState->last_error_submission <= target)
        {
            assignError(error, mCompletionState->last_error);
            mCompletionState->reported_through =
                std::max(mCompletionState->reported_through, target);
            return false;
        }

        mCompletionState->reported_through =
            std::max(mCompletionState->reported_through, target);
        return true;
    }

    bool waitForPresent(std::chrono::milliseconds timeout, std::string* error) noexcept
    {
        assignError(error, {});

        const std::uint64_t target =
            mCompletionState->submitted.load(std::memory_order_acquire);
        std::unique_lock lock(mCompletionState->mutex);
        const bool presented = mCompletionState->condition.wait_for(
            lock,
            timeout,
            [this, target] {
                return mCompletionState->presented.load(std::memory_order_acquire) >= target;
            });

        if (!presented)
        {
            assignError(error, "timed out waiting for Metal drawable presentation");
        }
        return presented;
    }

    std::uint64_t submittedFrameCount() const noexcept
    {
        return mCompletionState->submitted.load(std::memory_order_acquire);
    }

    std::uint64_t completedFrameCount() const noexcept
    {
        return mCompletionState->completed.load(std::memory_order_acquire);
    }

    std::uint64_t presentedFrameCount() const noexcept
    {
        return mCompletionState->presented.load(std::memory_order_acquire);
    }

    std::string capabilityReport() const
    {
        std::ostringstream report;
        report << "Metal device: " << toString(mDevice.name) << '\n'
               << "Registry ID: 0x" << std::hex << mDevice.registryID << std::dec << '\n'
               << "Unified memory: " << (mDevice.hasUnifiedMemory ? "yes" : "no") << '\n'
               << "Recommended working set: "
               << mDevice.recommendedMaxWorkingSetSize << " bytes\n"
               << "Maximum buffer length: " << mDevice.maxBufferLength << " bytes\n"
               << "GPU family Apple 7: "
               << ([mDevice supportsFamily:MTLGPUFamilyApple7] ? "yes" : "no") << '\n'
               << "GPU family Mac 2: "
               << ([mDevice supportsFamily:MTLGPUFamilyMac2] ? "yes" : "no") << '\n'
               << "Maximum in-flight frames: " << MAX_IN_FLIGHT_FRAMES << '\n'
               << "Shader library: " << mMetallibPath;
#if defined(LL_ACTIVE_METAL_VIEWER)
        std::lock_guard lock(mArtifactPreparation->mutex);
        report << '\n'
               << "Artifact program: " << mArtifactProgramName << '\n'
               << "Artifact reflection SHA-256: " << mArtifactReflectionSha256
               << '\n'
               << "Artifact preparation: "
               << toString(mArtifactPreparation->phase);
        if (!mArtifactPreparation->error.empty())
        {
            report << " (" << mArtifactPreparation->error << ')';
        }
#endif
        return report.str();
    }

private:
    MetalRenderer() = default;

    bool initialize(const std::string& metallib_path, std::string& error)
    {
        mDevice = MTLCreateSystemDefaultDevice();
        if (!mDevice)
        {
            error = "this Mac does not expose a Metal device";
            return false;
        }

        if (metallib_path.empty())
        {
            error = "the Metal shader library path is empty";
            return false;
        }

#if defined(LL_ACTIVE_METAL_VIEWER)
        mProgramLibrary = std::make_unique<MetalProgramLibrary>(
            (__bridge void*)mDevice, metallib_path);
        if (!mProgramLibrary->valid())
        {
            error = "could not load the declared Metal programs: " +
                    mProgramLibrary->error();
            return false;
        }
        mArtifactProgram = mProgramLibrary->program("presentation_copy");
        if (mArtifactProgram == nullptr ||
            !isPresentationCopyProgram(*mArtifactProgram, error))
        {
            if (error.empty())
            {
                error = "the declared program catalog is missing presentation_copy";
            }
            return false;
        }

        mPipelineCache = std::make_unique<MetalRenderPipelineFamilyCache>(
            *mProgramLibrary, mArtifactProgram->id);
        if (!mPipelineCache->valid())
        {
            error = "could not create the presentation_copy pipeline family";
            return false;
        }
        mArtifactPipeline = mPipelineCache->artifactPipeline(
            { BlendAttachmentDesc{} });
        if (!mArtifactPipeline)
        {
            error = "could not create the presentation_copy render pipeline";
            return false;
        }

        mSamplerCache = std::make_unique<MetalSamplerCache>(
            (__bridge void*)mDevice);
        const auto sampler = mSamplerCache->sampler(SamplerDesc{}, 1);
        if (!sampler)
        {
            error = "could not create the presentation_copy sampler";
            return false;
        }
        mSampler = *sampler;
        mTextureIndex = mArtifactProgram->fragmentBindings.textures[0].index;
        mSamplerIndex = mArtifactProgram->fragmentBindings.samplers[0].index;
        mArtifactProgramName = std::string(mArtifactProgram->name);
        mArtifactReflectionSha256 =
            std::string(mArtifactProgram->reflectionSha256);
#else
        NSString* library_path = [NSString stringWithUTF8String:metallib_path.c_str()];
        if (!library_path)
        {
            error = "the Metal shader library path is not valid UTF-8";
            return false;
        }

        NSError* library_error = nil;
        id<MTLLibrary> library = [mDevice
            newLibraryWithURL:[NSURL fileURLWithPath:library_path]
            error:&library_error];
        if (!library)
        {
            error = "could not load the offline Metal shader library: " +
                    toString(library_error);
            return false;
        }

        id<MTLFunction> vertex_function =
            [library newFunctionWithName:@"firestorm_bootstrap_vertex"];
        id<MTLFunction> fragment_function =
            [library newFunctionWithName:@"firestorm_bootstrap_fragment"];
        if (!vertex_function || !fragment_function)
        {
            error = "the Metal shader library is missing a bootstrap entry point";
            return false;
        }

        MTLRenderPipelineDescriptor* pipeline_descriptor =
            [[MTLRenderPipelineDescriptor alloc] init];
        pipeline_descriptor.label = @"Firestorm bootstrap pipeline";
        pipeline_descriptor.vertexFunction = vertex_function;
        pipeline_descriptor.fragmentFunction = fragment_function;
        pipeline_descriptor.colorAttachments[0].pixelFormat = pixelFormat();

        NSError* pipeline_error = nil;
        mPipeline = [mDevice
            newRenderPipelineStateWithDescriptor:pipeline_descriptor
            error:&pipeline_error];
        if (!mPipeline)
        {
            error = "could not create the Metal bootstrap pipeline: " +
                    toString(pipeline_error);
            return false;
        }
#endif

        mCommandQueue = [mDevice newCommandQueue];
        if (!mCommandQueue)
        {
            error = "could not create the Metal command queue";
            return false;
        }

        mRenderFrames = std::make_unique<MetalFrameContext>(
            (__bridge void*)mDevice, 4096);
        if (!mRenderFrames->valid())
        {
            error = "could not create the presentation frame contexts";
            return false;
        }
        mCompletionState = std::make_shared<CompletionState>();
#if defined(LL_ACTIVE_METAL_VIEWER)
        mArtifactPreparation = std::make_shared<ArtifactPreparationState>();
#endif
        mMetallibPath = metallib_path;
        return true;
    }

#if defined(LL_ACTIVE_METAL_VIEWER)
    bool beginArtifactPreparation(std::string& error)
    {
        const MetalVertexAttributeDescriptor& attribute =
            mArtifactProgram->vertexAttributes[0];
        const MetalVertexBufferLayoutDescriptor& layout =
            mArtifactProgram->vertexLayouts[0];
        const std::size_t stride = layout.stride;
        std::vector<std::byte> positions(stride * 3U);
        constexpr std::array<std::array<float, 3>, 3> TRIANGLE{{
            {{ -0.68F, -0.58F, 0.0F }},
            {{  0.68F, -0.58F, 0.0F }},
            {{  0.0F,   0.68F, 0.0F }},
        }};
        for (std::size_t index = 0; index < TRIANGLE.size(); ++index)
        {
            std::memcpy(positions.data() + index * stride + attribute.offset,
                        TRIANGLE[index].data(),
                        sizeof(TRIANGLE[index]));
        }

        constexpr std::array<std::byte, 16> TEXTURE{{
            std::byte{0xff}, std::byte{0x30}, std::byte{0x80}, std::byte{0xff},
            std::byte{0x30}, std::byte{0xc0}, std::byte{0xff}, std::byte{0xff},
            std::byte{0xff}, std::byte{0xd0}, std::byte{0x30}, std::byte{0xff},
            std::byte{0x80}, std::byte{0x30}, std::byte{0xff}, std::byte{0xff},
        }};

        const auto lease = mRenderFrames->tryBegin();
        if (!lease)
        {
            error = "artifact upload frame context was unexpectedly busy";
            return false;
        }
        id<MTLCommandBuffer> command_buffer = [mCommandQueue commandBuffer];
        if (command_buffer == nil)
        {
            mRenderFrames->cancel(lease->token);
            error = "could not create the artifact upload command buffer";
            return false;
        }
        command_buffer.label = @"Firestorm presentation_copy resource upload";

        MetalTransferBatch batch((__bridge void*)mDevice,
                                 *mRenderFrames,
                                 *lease,
                                 (__bridge void*)command_buffer,
                                 0);
        if (!batch.valid())
        {
            mRenderFrames->cancel(lease->token);
            error = "could not create the artifact transfer batch";
            return false;
        }

        const auto preparation = mArtifactPreparation;
        const MetalTransferStatus buffer_status = batch.uploadPrivateBuffer(
            { positions.data(), positions.size() },
            "Firestorm presentation_copy positions",
            [preparation](std::uint64_t, MetalPrivateBuffer buffer) {
                std::lock_guard lock(preparation->mutex);
                preparation->positions = std::move(buffer);
            });
        if (buffer_status != MetalTransferStatus::encoded)
        {
            batch.cancel();
            error = "could not encode the private presentation position upload";
            return false;
        }

        MetalTextureDescriptor texture_descriptor;
        texture_descriptor.format = PixelFormat::rgba8_unorm;
        texture_descriptor.width = 2;
        texture_descriptor.height = 2;
        texture_descriptor.mipLevels = 1;
        texture_descriptor.usage = MetalTextureUsage::shader_read;
        texture_descriptor.label = "Firestorm presentation_copy sampled texture";
        const std::vector<MetalTextureSubresourceUpload> texture_uploads{
            MetalTextureSubresourceUpload{
                0,
                0,
                { TEXTURE.data(), TEXTURE.size() },
                8,
            },
        };
        const MetalTransferStatus texture_status = batch.uploadPrivateTexture(
            texture_descriptor,
            texture_uploads,
            [preparation](std::uint64_t, MetalPrivateTexture texture) {
                std::lock_guard lock(preparation->mutex);
                preparation->texture = std::move(texture);
            });
        if (texture_status != MetalTransferStatus::encoded)
        {
            batch.cancel();
            error = "could not encode the private presentation texture upload";
            return false;
        }

        auto transfer_completion = batch.finish();
        if (!transfer_completion)
        {
            mRenderFrames->cancel(lease->token);
            error = "could not finish the artifact transfer batch";
            return false;
        }

        const auto completion_state = mCompletionState;
        MetalFrameContext::CompletionAction preparation_completion =
            [publish = std::move(*transfer_completion),
             preparation,
             completion_state](std::uint64_t serial) mutable {
                publish(serial);
                std::string terminal_error;
                {
                    std::lock_guard lock(preparation->mutex);
                    if (preparation->phase == ArtifactPreparationPhase::failed)
                    {
                        return;
                    }
                    if (preparation->positions && preparation->texture)
                    {
                        preparation->phase = ArtifactPreparationPhase::uploaded;
                    }
                    else
                    {
                        preparation->phase = ArtifactPreparationPhase::failed;
                        preparation->error =
                            "artifact upload completed without both resources";
                        terminal_error = preparation->error;
                    }
                }
                if (!terminal_error.empty())
                {
                    publishTerminalFailureOnce(
                        completion_state, std::move(terminal_error));
                }
                notifyFrameSlotAvailable(completion_state);
            };
        const auto serial = mRenderFrames->submit(
            lease->token,
            (__bridge void*)command_buffer,
            std::move(preparation_completion));
        if (!serial)
        {
            mRenderFrames->cancel(lease->token);
            error = "could not submit the artifact transfer batch";
            return false;
        }

        [command_buffer addCompletedHandler:^(id<MTLCommandBuffer> completed_buffer) {
            @autoreleasepool
            {
                if (completed_buffer.status == MTLCommandBufferStatusCompleted)
                {
                    return;
                }
                std::string terminal_error = "artifact upload GPU failure: " +
                                             toString(completed_buffer.error);
                {
                    std::lock_guard lock(preparation->mutex);
                    preparation->phase = ArtifactPreparationPhase::failed;
                    preparation->error = terminal_error;
                }
                publishTerminalFailureOnce(
                    completion_state, std::move(terminal_error));
                notifyFrameSlotAvailable(completion_state);
            }
        }];
        [command_buffer commit];
        return true;
    }

    FrameSubmission prepareArtifactForRender(std::string* error) noexcept
    {
        std::lock_guard lock(mArtifactPreparation->mutex);
        if (mArtifactPreparation->phase == ArtifactPreparationPhase::preparing)
        {
            return FrameSubmission::renderer_busy;
        }
        if (mArtifactPreparation->phase == ArtifactPreparationPhase::failed)
        {
            assignError(error, mArtifactPreparation->error);
            return FrameSubmission::failed;
        }
        if (mArtifactPreparation->phase == ArtifactPreparationPhase::uploaded)
        {
            std::vector<MetalVertexStreamBinding> streams;
            streams.push_back(MetalVertexStreamBinding{
                mArtifactProgram->vertexLayouts[0].bufferIndex,
                *mArtifactPreparation->positions,
                0,
            });
            mArtifactGeometry = makeArtifactGeometry(
                *mProgramLibrary,
                mArtifactProgram->id,
                std::move(streams));
            if (!mArtifactGeometry)
            {
                mArtifactPreparation->phase = ArtifactPreparationPhase::failed;
                mArtifactPreparation->error =
                    "artifact geometry rejected the uploaded position stream";
                assignError(error, mArtifactPreparation->error);
                return FrameSubmission::failed;
            }
            mArtifactTexture = *mArtifactPreparation->texture;
            mArtifactPreparation->phase = ArtifactPreparationPhase::ready;
        }
        return FrameSubmission::submitted;
    }
#endif

    id<MTLDevice> mDevice = nil;
    id<MTLCommandQueue> mCommandQueue = nil;
#if defined(LL_ACTIVE_METAL_VIEWER)
    std::unique_ptr<MetalProgramLibrary> mProgramLibrary;
    const MetalProgramDescriptor* mArtifactProgram = nullptr;
    std::unique_ptr<MetalRenderPipelineFamilyCache> mPipelineCache;
    std::optional<MetalArtifactPipeline> mArtifactPipeline;
    std::unique_ptr<MetalSamplerCache> mSamplerCache;
    MetalSamplerHandle mSampler = nullptr;
    std::optional<MetalArtifactGeometry> mArtifactGeometry;
    std::optional<MetalPrivateTexture> mArtifactTexture;
    std::shared_ptr<ArtifactPreparationState> mArtifactPreparation;
    std::uint8_t mTextureIndex = 0;
    std::uint8_t mSamplerIndex = 0;
    std::string mArtifactProgramName;
    std::string mArtifactReflectionSha256;
#else
    id<MTLRenderPipelineState> mPipeline = nil;
#endif
    std::unique_ptr<MetalFrameContext> mRenderFrames;
    std::shared_ptr<CompletionState> mCompletionState;
    std::string mMetallibPath;
};

} // namespace
} // namespace firestorm::metal

@interface LLMetalBootstrapView : NSView
{
@private
    std::shared_ptr<firestorm::metal::MetalRenderer> mRenderer;
    BOOL mFrameRetryPending;
    BOOL mDrawableRetryAttempted;
    BOOL mDrawableRetryQueued;
    BOOL mSimulateDrawableUnavailableOnce;
    BOOL mSelfTestBypassVisibility;
    BOOL mDisplayPassQueued;
}

- (instancetype)initWithRenderer:
    (std::shared_ptr<firestorm::metal::MetalRenderer>)renderer;
- (firestorm::metal::FrameSubmission)drawMetalFrameWithError:(std::string*)error;
- (void)requestMetalFrame;
- (void)frameSlotDidBecomeAvailable;
- (void)scheduleDrawableRetry;
- (void)simulateDrawableUnavailableOnceForSelfTest;
- (void)updateDrawableSize;

@end

@implementation LLMetalBootstrapView

- (instancetype)initWithRenderer:
    (std::shared_ptr<firestorm::metal::MetalRenderer>)renderer
{
    self = [super initWithFrame:NSMakeRect(0.0, 0.0, 960.0, 600.0)];
    if (!self)
    {
        return nil;
    }

    mRenderer = std::move(renderer);
    __weak LLMetalBootstrapView* weak_self = self;
    mRenderer->setFrameSlotAvailableHandler([weak_self] {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weak_self frameSlotDidBecomeAvailable];
        });
    });

    CAMetalLayer* metal_layer = [CAMetalLayer layer];
    metal_layer.device = mRenderer->device();
    metal_layer.pixelFormat = mRenderer->pixelFormat();
    metal_layer.framebufferOnly = YES;
    metal_layer.maximumDrawableCount = firestorm::metal::MAX_IN_FLIGHT_FRAMES;
    metal_layer.allowsNextDrawableTimeout = YES;
    metal_layer.displaySyncEnabled = YES;
    metal_layer.presentsWithTransaction = NO;

    self.layer = metal_layer;
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    [self updateDrawableSize];
#if defined(LL_ACTIVE_METAL_VIEWER)
    mRenderer->setTerminalFailureHandler([weak_self](std::string message) {
        auto retained_message =
            std::make_shared<std::string>(std::move(message));
        dispatch_async(dispatch_get_main_queue(), ^{
            LLMetalBootstrapView* strong_self = weak_self;
            if (!strong_self)
            {
                return;
            }
            reportActiveMetalBootstrapTerminalFailure(
                retained_message->c_str());
        });
    });
#endif
    return self;
}

- (void)dealloc
{
#if defined(LL_ACTIVE_METAL_VIEWER)
    mRenderer->setTerminalFailureHandler({});
#endif
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isOpaque
{
    return YES;
}

#if defined(LL_ACTIVE_METAL_VIEWER)
- (NSView*)hitTest:(NSPoint)point
{
    (void)point;
    return nil;
}
#endif

- (BOOL)wantsUpdateLayer
{
    return YES;
}

- (void)updateLayer
{
    const BOOL is_drawable_retry = mDrawableRetryQueued;
    mDrawableRetryQueued = NO;
    if (!is_drawable_retry)
    {
        mDrawableRetryAttempted = NO;
    }

    NSWindow* window = self.window;
    if (!mSelfTestBypassVisibility &&
        (!window || window.miniaturized || !window.visible ||
         !(window.occlusionState & NSWindowOcclusionStateVisible)))
    {
        return;
    }

    std::string error;
    const auto result = [self drawMetalFrameWithError:&error];
    if (result == firestorm::metal::FrameSubmission::failed)
    {
        mSelfTestBypassVisibility = NO;
#if !defined(LL_ACTIVE_METAL_VIEWER)
        NSLog(@"Firestorm Metal bootstrap frame failed: %s", error.c_str());
#endif
    }
    else if (result == firestorm::metal::FrameSubmission::renderer_busy)
    {
        mSelfTestBypassVisibility = NO;
        mDrawableRetryAttempted = NO;
        mFrameRetryPending = YES;
    }
    else if (result == firestorm::metal::FrameSubmission::drawable_unavailable)
    {
        if (is_drawable_retry)
        {
            mSelfTestBypassVisibility = NO;
        }
        mFrameRetryPending = NO;
        [self scheduleDrawableRetry];
    }
    else
    {
        mSelfTestBypassVisibility = NO;
        mDrawableRetryAttempted = NO;
        mFrameRetryPending = NO;
    }
}

- (void)setFrameSize:(NSSize)new_size
{
    [super setFrameSize:new_size];
    [self updateDrawableSize];
    [self requestMetalFrame];
}

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self updateDrawableSize];
    [self requestMetalFrame];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowDidChangeOcclusionStateNotification
                                                  object:nil];

    if (self.window)
    {
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(windowOcclusionDidChange:)
                   name:NSWindowDidChangeOcclusionStateNotification
                 object:self.window];
        [self updateDrawableSize];
        [self requestMetalFrame];
    }
}

- (void)windowOcclusionDidChange:(NSNotification*)notification
{
    (void)notification;
    if (self.window.occlusionState & NSWindowOcclusionStateVisible)
    {
        [self requestMetalFrame];
    }
}

- (void)requestMetalFrame
{
    if (mDisplayPassQueued)
    {
        return;
    }

    mDisplayPassQueued = YES;
    __weak LLMetalBootstrapView* weak_self = self;
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        LLMetalBootstrapView* strong_self = weak_self;
        if (!strong_self)
        {
            return;
        }
        strong_self->mDisplayPassQueued = NO;
        [strong_self updateLayer];
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

- (void)frameSlotDidBecomeAvailable
{
    if (mFrameRetryPending)
    {
        mFrameRetryPending = NO;
        [self requestMetalFrame];
    }
}

- (void)scheduleDrawableRetry
{
    if (mDrawableRetryAttempted || mDrawableRetryQueued)
    {
        return;
    }

    mDrawableRetryAttempted = YES;
    mDrawableRetryQueued = YES;
    __weak LLMetalBootstrapView* weak_self = self;
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        LLMetalBootstrapView* strong_self = weak_self;
        if (strong_self && strong_self->mDrawableRetryQueued)
        {
            [strong_self updateLayer];
        }
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

- (void)simulateDrawableUnavailableOnceForSelfTest
{
    mSimulateDrawableUnavailableOnce = YES;
    mSelfTestBypassVisibility = YES;
}

- (void)updateDrawableSize
{
    CAMetalLayer* metal_layer = (CAMetalLayer*)self.layer;
    if (![metal_layer isKindOfClass:[CAMetalLayer class]])
    {
        return;
    }

    const NSSize backing_size = [self convertSizeToBacking:self.bounds.size];
    metal_layer.drawableSize = CGSizeMake(
        std::max(0.0, backing_size.width),
        std::max(0.0, backing_size.height));

    const CGFloat scale = self.window ? self.window.backingScaleFactor : 1.0;
    metal_layer.contentsScale = std::max(1.0, scale);
}

- (firestorm::metal::FrameSubmission)drawMetalFrameWithError:(std::string*)error
{
    [self updateDrawableSize];
    if (mSimulateDrawableUnavailableOnce)
    {
        mSimulateDrawableUnavailableOnce = NO;
        if (error)
        {
            error->clear();
        }
        return firestorm::metal::FrameSubmission::drawable_unavailable;
    }
    const auto result = mRenderer->render((CAMetalLayer*)self.layer, error);
#if defined(LL_ACTIVE_METAL_VIEWER)
    if (result == firestorm::metal::FrameSubmission::failed)
    {
        mRenderer->reportTerminalFailure(
            error && !error->empty()
            ? *error
            : "Metal bootstrap frame submission failed");
    }
#endif
    return result;
}

@end

namespace firestorm::metal
{

struct LLMetalBootstrap::Impl
{
    std::shared_ptr<MetalRenderer> renderer;
    LLMetalBootstrapView* view;
};

const char* toString(FrameSubmission submission) noexcept
{
    switch (submission)
    {
        case FrameSubmission::submitted:
            return "submitted";
        case FrameSubmission::drawable_unavailable:
            return "drawable unavailable";
        case FrameSubmission::renderer_busy:
            return "renderer busy";
        case FrameSubmission::failed:
            return "failed";
    }

    return "unknown";
}

std::unique_ptr<LLMetalBootstrap> LLMetalBootstrap::create(
    const std::string& metallib_path,
    std::string& error)
{
    error.clear();
    if (![NSThread isMainThread])
    {
        error = "the Metal bootstrap view must be created on the AppKit main thread";
        return {};
    }

    auto renderer = MetalRenderer::create(metallib_path, error);
    if (!renderer)
    {
        return {};
    }

    LLMetalBootstrapView* view =
        [[LLMetalBootstrapView alloc] initWithRenderer:renderer];
    if (!view)
    {
        error = "could not create the Metal bootstrap view";
        return {};
    }

    auto implementation = std::make_unique<Impl>();
    implementation->renderer = std::move(renderer);
    implementation->view = view;
    return std::unique_ptr<LLMetalBootstrap>(
        new LLMetalBootstrap(std::move(implementation)));
}

LLMetalBootstrap::LLMetalBootstrap(std::unique_ptr<Impl> implementation)
: mImpl(std::move(implementation))
{
}

LLMetalBootstrap::~LLMetalBootstrap() = default;

void* LLMetalBootstrap::nativeView() const noexcept
{
    return (__bridge void*)mImpl->view;
}

bool LLMetalBootstrap::attachToNativeView(
    void* native_view,
    std::string* error) noexcept
{
    if (![NSThread isMainThread])
    {
        assignError(error, "the Metal bootstrap view must be attached on the AppKit main thread");
        return false;
    }

    NSView* host_view = (__bridge NSView*)native_view;
    if (!host_view)
    {
        assignError(error, "the Metal bootstrap input host is null");
        return false;
    }

    LLMetalBootstrapView* view = mImpl->view;
    [view removeFromSuperview];
    view.frame = host_view.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [host_view addSubview:view];
    [view updateDrawableSize];
    [view requestMetalFrame];
    if (error)
    {
        error->clear();
    }
    return true;
}

void LLMetalBootstrap::detachFromNativeView() noexcept
{
    LLMetalBootstrapView* view = mImpl->view;
    if ([NSThread isMainThread])
    {
        [view removeFromSuperview];
        return;
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        [view removeFromSuperview];
    });
}

void LLMetalBootstrap::requestFrame() noexcept
{
    LLMetalBootstrapView* view = mImpl->view;
    if ([NSThread isMainThread])
    {
        [view requestMetalFrame];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [view requestMetalFrame];
    });
}

FrameSubmission LLMetalBootstrap::drawFrame(std::string* error) noexcept
{
    if (![NSThread isMainThread])
    {
        assignError(error, "Metal frames must be submitted on the AppKit main thread");
        return FrameSubmission::failed;
    }

    return [mImpl->view drawMetalFrameWithError:error];
}

bool LLMetalBootstrap::waitForIdle(
    std::chrono::milliseconds timeout,
    std::string* error) noexcept
{
    return mImpl->renderer->waitForIdle(timeout, error);
}

bool LLMetalBootstrap::waitForPresent(
    std::chrono::milliseconds timeout,
    std::string* error) noexcept
{
    return mImpl->renderer->waitForPresent(timeout, error);
}

std::uint64_t LLMetalBootstrap::submittedFrameCount() const noexcept
{
    return mImpl->renderer->submittedFrameCount();
}

std::uint64_t LLMetalBootstrap::completedFrameCount() const noexcept
{
    return mImpl->renderer->completedFrameCount();
}

std::uint64_t LLMetalBootstrap::presentedFrameCount() const noexcept
{
    return mImpl->renderer->presentedFrameCount();
}

std::uint32_t LLMetalBootstrap::drawableWidth() const noexcept
{
    CAMetalLayer* layer = (CAMetalLayer*)mImpl->view.layer;
    return static_cast<std::uint32_t>(std::max(0.0, layer.drawableSize.width));
}

std::uint32_t LLMetalBootstrap::drawableHeight() const noexcept
{
    CAMetalLayer* layer = (CAMetalLayer*)mImpl->view.layer;
    return static_cast<std::uint32_t>(std::max(0.0, layer.drawableSize.height));
}

std::string LLMetalBootstrap::capabilityReport() const
{
    return mImpl->renderer->capabilityReport();
}

} // namespace firestorm::metal
