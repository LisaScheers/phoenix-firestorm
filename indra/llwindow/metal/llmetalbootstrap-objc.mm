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

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <functional>
#include <iomanip>
#include <memory>
#include <mutex>
#include <sstream>
#include <utility>

namespace firestorm::metal
{
namespace
{

constexpr std::uint32_t MAX_IN_FLIGHT_FRAMES = 3;

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
};

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

    FrameSubmission render(CAMetalLayer* layer, std::string* error) noexcept
    {
        assignError(error, {});

        if (![NSThread isMainThread])
        {
            assignError(error, "Metal frames must be submitted on the AppKit main thread");
            return FrameSubmission::failed;
        }

        if (!layer || layer.drawableSize.width < 1.0 || layer.drawableSize.height < 1.0)
        {
            return FrameSubmission::drawable_unavailable;
        }

        if (dispatch_semaphore_wait(mInFlightFrames, DISPATCH_TIME_NOW) != 0)
        {
            return FrameSubmission::renderer_busy;
        }

        id<MTLCommandBuffer> command_buffer = [mCommandQueue commandBuffer];
        if (!command_buffer)
        {
            dispatch_semaphore_signal(mInFlightFrames);
            assignError(error, "Metal failed to create a command buffer");
            return FrameSubmission::failed;
        }

        command_buffer.label = @"Firestorm Metal bootstrap frame";

        // Keep drawable acquisition after CPU-side setup and in-flight gating.
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (!drawable)
        {
            dispatch_semaphore_signal(mInFlightFrames);
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
            dispatch_semaphore_signal(mInFlightFrames);
            assignError(error, "Metal failed to create a render command encoder");
            return FrameSubmission::failed;
        }

        encoder.label = @"Firestorm bootstrap clear and triangle";
        [encoder setRenderPipelineState:mPipeline];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
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

        const std::uint64_t submission =
            mCompletionState->submitted.fetch_add(1, std::memory_order_release) + 1;
        const auto completion_state = mCompletionState;
        dispatch_semaphore_t in_flight_frames = mInFlightFrames;
        [command_buffer addCompletedHandler:^(id<MTLCommandBuffer> completed_buffer) {
            @autoreleasepool
            {
                std::string completion_error;
                std::function<void()> frame_slot_available;
                if (completed_buffer.status == MTLCommandBufferStatusError)
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
                            completion_state->last_error = std::move(completion_error);
                        }
                    }
                    completion_state->completed.fetch_add(1, std::memory_order_release);
                    frame_slot_available = completion_state->frame_slot_available;
                }

                dispatch_semaphore_signal(in_flight_frames);
                completion_state->condition.notify_all();
                if (frame_slot_available)
                {
                    frame_slot_available();
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

        mCommandQueue = [mDevice newCommandQueue];
        if (!mCommandQueue)
        {
            error = "could not create the Metal command queue";
            return false;
        }

        mInFlightFrames = dispatch_semaphore_create(MAX_IN_FLIGHT_FRAMES);
        mCompletionState = std::make_shared<CompletionState>();
        mMetallibPath = metallib_path;
        return true;
    }

    id<MTLDevice> mDevice = nil;
    id<MTLCommandQueue> mCommandQueue = nil;
    id<MTLRenderPipelineState> mPipeline = nil;
    dispatch_semaphore_t mInFlightFrames = nullptr;
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
    return self;
}

- (void)dealloc
{
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
        NSLog(@"Firestorm Metal bootstrap frame failed: %s", error.c_str());
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
    return mRenderer->render((CAMetalLayer*)self.layer, error);
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
