/**
 * @file llmetalrenderpass-objc.mm
 * @brief Native validation and encoding for typed Metal render passes.
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

#include "llmetalrenderpass.h"

#include <cmath>
#include <optional>
#include <utility>

namespace firestorm::metal
{
namespace
{

bool conformsToMetalProtocol(void* handle, Protocol* protocol)
{
    id object = (__bridge id)handle;
    return object != nil && [object conformsToProtocol:protocol];
}

constexpr bool isColorFormat(PixelFormat format) noexcept
{
    switch (format)
    {
        case PixelFormat::bgra8_unorm:
        case PixelFormat::rgba8_unorm:
        case PixelFormat::rgba16_unorm:
        case PixelFormat::rgba16_float:
        case PixelFormat::rg11b10_float:
            return true;
        case PixelFormat::depth32_float:
            return false;
    }
    return false;
}

constexpr bool isDepthFormat(PixelFormat format) noexcept
{
    switch (format)
    {
        case PixelFormat::depth32_float:
            return true;
        case PixelFormat::bgra8_unorm:
        case PixelFormat::rgba8_unorm:
        case PixelFormat::rgba16_unorm:
        case PixelFormat::rgba16_float:
        case PixelFormat::rg11b10_float:
            return false;
    }
    return false;
}

std::optional<MTLPixelFormat> nativePixelFormat(PixelFormat format) noexcept
{
    switch (format)
    {
        case PixelFormat::bgra8_unorm:
            return MTLPixelFormatBGRA8Unorm;
        case PixelFormat::rgba8_unorm:
            return MTLPixelFormatRGBA8Unorm;
        case PixelFormat::rgba16_unorm:
            return MTLPixelFormatRGBA16Unorm;
        case PixelFormat::rgba16_float:
            return MTLPixelFormatRGBA16Float;
        case PixelFormat::rg11b10_float:
            return MTLPixelFormatRG11B10Float;
        case PixelFormat::depth32_float:
            return MTLPixelFormatDepth32Float;
    }
    return std::nullopt;
}

std::optional<MTLLoadAction>
nativeLoadAction(AttachmentLoadAction action) noexcept
{
    switch (action)
    {
        case AttachmentLoadAction::dont_care:
            return MTLLoadActionDontCare;
        case AttachmentLoadAction::load:
            return MTLLoadActionLoad;
        case AttachmentLoadAction::clear:
            return MTLLoadActionClear;
    }
    return std::nullopt;
}

std::optional<MTLStoreAction>
nativeStoreAction(AttachmentStoreAction action) noexcept
{
    switch (action)
    {
        case AttachmentStoreAction::dont_care:
            return MTLStoreActionDontCare;
        case AttachmentStoreAction::store:
            return MTLStoreActionStore;
    }
    return std::nullopt;
}

bool finite(MetalClearColor color) noexcept
{
    return std::isfinite(color.red) && std::isfinite(color.green) &&
           std::isfinite(color.blue) && std::isfinite(color.alpha);
}

bool validDepthClear(double value) noexcept
{
    return std::isfinite(value) && value >= 0.0 && value <= 1.0;
}

bool isPreCommit(MTLCommandBufferStatus status) noexcept
{
    return status == MTLCommandBufferStatusNotEnqueued ||
           status == MTLCommandBufferStatusEnqueued;
}

bool validNativeTexture(id<MTLTexture> texture,
                        const MetalPrivateTexture2D& wrapper,
                        MTLPixelFormat expected_format) noexcept
{
    return texture != nil && texture.storageMode == MTLStorageModePrivate &&
           texture.textureType == MTLTextureType2D && texture.arrayLength == 1 &&
           texture.mipmapLevelCount == 1 && texture.sampleCount == 1 &&
           texture.pixelFormat == expected_format &&
           (texture.usage & MTLTextureUsageRenderTarget) != 0 &&
           texture.width == wrapper.width() && texture.height == wrapper.height();
}

} // namespace

struct MetalRenderTarget::Impl
{
    Impl(MetalPrivateTexture2D native_color,
         std::optional<MetalPrivateTexture2D> native_depth) :
        color(std::move(native_color)),
        depth(std::move(native_depth))
    {
    }

    MetalPrivateTexture2D color;
    std::optional<MetalPrivateTexture2D> depth;
};

MetalRenderTarget::MetalRenderTarget(std::shared_ptr<const Impl> impl) noexcept :
    mImpl(std::move(impl))
{
}

bool MetalRenderTarget::valid() const noexcept
{
    return mImpl != nullptr && mImpl->color.valid() &&
           (!mImpl->depth || mImpl->depth->valid());
}

std::uint32_t MetalRenderTarget::width() const noexcept
{
    return valid() ? mImpl->color.width() : 0;
}

std::uint32_t MetalRenderTarget::height() const noexcept
{
    return valid() ? mImpl->color.height() : 0;
}

std::uint32_t MetalRenderTarget::sampleCount() const noexcept
{
    return valid() ? 1U : 0U;
}

PixelFormat MetalRenderTarget::colorFormat() const noexcept
{
    return valid() ? mImpl->color.format() : PixelFormat::rgba8_unorm;
}

std::optional<PixelFormat> MetalRenderTarget::depthFormat() const noexcept
{
    return valid() && mImpl->depth
        ? std::optional<PixelFormat>(mImpl->depth->format())
        : std::nullopt;
}

MetalPrivateTexture2D MetalRenderTarget::colorTexture() const noexcept
{
    return valid() ? mImpl->color : MetalPrivateTexture2D{};
}

std::optional<MetalPrivateTexture2D>
MetalRenderTarget::depthTexture() const noexcept
{
    return valid() ? mImpl->depth : std::nullopt;
}

std::optional<MetalRenderTarget>
makeRenderTarget(MetalPrivateTexture2D color,
                 std::optional<MetalPrivateTexture2D> depth)
{
    if (!color.valid() || !isColorFormat(color.format()) ||
        !hasUsage(color.usage(), MetalTextureUsage::render_target) ||
        color.mipLevels() != 1)
    {
        return std::nullopt;
    }

    const auto expected_color_format = nativePixelFormat(color.format());
    if (!expected_color_format ||
        !conformsToMetalProtocol(color.nativeHandle(), @protocol(MTLTexture)))
    {
        return std::nullopt;
    }

    id<MTLTexture> native_color =
        (__bridge id<MTLTexture>)color.nativeHandle();
    if (!validNativeTexture(native_color, color, *expected_color_format))
    {
        return std::nullopt;
    }

    if (depth)
    {
        if (!depth->valid() || !isDepthFormat(depth->format()) ||
            !hasUsage(depth->usage(), MetalTextureUsage::render_target) ||
            depth->mipLevels() != 1 || depth->width() != color.width() ||
            depth->height() != color.height())
        {
            return std::nullopt;
        }

        const auto expected_depth_format = nativePixelFormat(depth->format());
        if (!expected_depth_format ||
            !conformsToMetalProtocol(depth->nativeHandle(), @protocol(MTLTexture)))
        {
            return std::nullopt;
        }

        id<MTLTexture> native_depth =
            (__bridge id<MTLTexture>)depth->nativeHandle();
        if (!validNativeTexture(native_depth, *depth, *expected_depth_format) ||
            native_depth.device != native_color.device ||
            native_depth.width != native_color.width ||
            native_depth.height != native_color.height ||
            native_depth.sampleCount != native_color.sampleCount)
        {
            return std::nullopt;
        }
    }

    MetalRenderTarget target(std::make_shared<const MetalRenderTarget::Impl>(
        std::move(color), std::move(depth)));
    return std::optional<MetalRenderTarget>(std::move(target));
}

struct MetalRenderPass::Impl
{
    Impl(id<MTLRenderCommandEncoder> native_encoder,
         MetalRenderTarget native_target) :
        encoder(native_encoder),
        target(std::move(native_target))
    {
    }

    ~Impl()
    {
        end();
    }

    bool end() noexcept
    {
        if (encoder == nil)
        {
            return false;
        }

        id<MTLRenderCommandEncoder> active_encoder = encoder;
        encoder = nil;
        [active_encoder endEncoding];
        return true;
    }

    __strong id<MTLRenderCommandEncoder> encoder;
    MetalRenderTarget target;
};

MetalRenderPass::MetalRenderPass(std::unique_ptr<Impl> impl) noexcept :
    mImpl(std::move(impl))
{
}

MetalRenderPass::~MetalRenderPass() = default;
MetalRenderPass::MetalRenderPass(MetalRenderPass&&) noexcept = default;
MetalRenderPass& MetalRenderPass::operator=(MetalRenderPass&&) noexcept = default;

bool MetalRenderPass::active() const noexcept
{
    return mImpl != nullptr && mImpl->encoder != nil;
}

MetalRenderEncoderHandle MetalRenderPass::encoder() const noexcept
{
    return active() ? (__bridge void*)mImpl->encoder : nullptr;
}

bool MetalRenderPass::end() noexcept
{
    return mImpl != nullptr && mImpl->end();
}

std::optional<MetalRenderPass>
beginRenderPass(MetalCommandBufferHandle command_buffer_handle,
                const MetalRenderTarget& target,
                const MetalRenderPassDesc& descriptor)
{
    if (!target.valid() ||
        descriptor.depth.has_value() != target.depthFormat().has_value() ||
        !conformsToMetalProtocol(command_buffer_handle,
                                @protocol(MTLCommandBuffer)))
    {
        return std::nullopt;
    }

    const auto color_load = nativeLoadAction(descriptor.color.load);
    const auto color_store = nativeStoreAction(descriptor.color.store);
    if (!color_load || !color_store ||
        (descriptor.color.load == AttachmentLoadAction::clear &&
         !finite(descriptor.color.clear)))
    {
        return std::nullopt;
    }

    std::optional<MTLLoadAction> depth_load;
    std::optional<MTLStoreAction> depth_store;
    if (descriptor.depth)
    {
        depth_load = nativeLoadAction(descriptor.depth->load);
        depth_store = nativeStoreAction(descriptor.depth->store);
        if (!depth_load || !depth_store ||
            (descriptor.depth->load == AttachmentLoadAction::clear &&
             !validDepthClear(descriptor.depth->clear)))
        {
            return std::nullopt;
        }
    }

    NSString* native_label = nil;
    if (!descriptor.label.empty())
    {
        native_label = [[NSString alloc]
            initWithBytes:descriptor.label.data()
                   length:descriptor.label.size()
                 encoding:NSUTF8StringEncoding];
        if (native_label == nil)
        {
            return std::nullopt;
        }
    }

    id<MTLCommandBuffer> command_buffer =
        (__bridge id<MTLCommandBuffer>)command_buffer_handle;
    MetalPrivateTexture2D color = target.colorTexture();
    if (!color.valid() || !isPreCommit(command_buffer.status))
    {
        return std::nullopt;
    }

    id<MTLTexture> native_color =
        (__bridge id<MTLTexture>)color.nativeHandle();
    if (native_color == nil || command_buffer.device != native_color.device)
    {
        return std::nullopt;
    }

    std::optional<MetalPrivateTexture2D> depth = target.depthTexture();
    id<MTLTexture> native_depth = depth
        ? (__bridge id<MTLTexture>)depth->nativeHandle()
        : nil;
    if ((depth && native_depth == nil) ||
        (native_depth != nil && native_depth.device != command_buffer.device))
    {
        return std::nullopt;
    }

    MTLRenderPassDescriptor* native_descriptor =
        [MTLRenderPassDescriptor renderPassDescriptor];
    MTLRenderPassColorAttachmentDescriptor* color_attachment =
        native_descriptor.colorAttachments[0];
    color_attachment.texture = native_color;
    color_attachment.level = 0;
    color_attachment.slice = 0;
    color_attachment.loadAction = *color_load;
    color_attachment.storeAction = *color_store;
    if (descriptor.color.load == AttachmentLoadAction::clear)
    {
        color_attachment.clearColor = MTLClearColorMake(
            descriptor.color.clear.red,
            descriptor.color.clear.green,
            descriptor.color.clear.blue,
            descriptor.color.clear.alpha);
    }

    if (descriptor.depth)
    {
        MTLRenderPassDepthAttachmentDescriptor* depth_attachment =
            native_descriptor.depthAttachment;
        depth_attachment.texture = native_depth;
        depth_attachment.level = 0;
        depth_attachment.slice = 0;
        depth_attachment.loadAction = *depth_load;
        depth_attachment.storeAction = *depth_store;
        if (descriptor.depth->load == AttachmentLoadAction::clear)
        {
            depth_attachment.clearDepth = descriptor.depth->clear;
        }
    }

    id<MTLRenderCommandEncoder> encoder =
        [command_buffer renderCommandEncoderWithDescriptor:native_descriptor];
    if (encoder == nil)
    {
        return std::nullopt;
    }
    if (native_label != nil)
    {
        encoder.label = native_label;
    }

    MetalRenderPass pass(std::make_unique<MetalRenderPass::Impl>(
        encoder, target));
    return std::optional<MetalRenderPass>(std::move(pass));
}

} // namespace firestorm::metal
