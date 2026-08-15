/**
 * @file llmetalresource-objc.mm
 * @brief Objective-C++ ownership and creation of private Metal resources.
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

#include <algorithm>
#include <limits>
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

std::optional<MTLPixelFormat> nativePixelFormat(PixelFormat format) noexcept
{
    switch (format)
    {
        case PixelFormat::bgra8_unorm:
            return MTLPixelFormatBGRA8Unorm;
        case PixelFormat::rgba8_unorm:
            return MTLPixelFormatRGBA8Unorm;
        case PixelFormat::rgba8_unorm_srgb:
            return MTLPixelFormatRGBA8Unorm_sRGB;
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

constexpr std::uint8_t kKnownTextureUsage =
    static_cast<std::uint8_t>(MetalTextureUsage::shader_read) |
    static_cast<std::uint8_t>(MetalTextureUsage::shader_write) |
    static_cast<std::uint8_t>(MetalTextureUsage::render_target);

std::optional<MTLTextureUsage> nativeTextureUsage(MetalTextureUsage usage) noexcept
{
    const std::uint8_t bits = static_cast<std::uint8_t>(usage);
    if (bits == 0 || (bits & static_cast<std::uint8_t>(~kKnownTextureUsage)) != 0)
    {
        return std::nullopt;
    }

    MTLTextureUsage native = MTLTextureUsageUnknown;
    if (hasUsage(usage, MetalTextureUsage::shader_read))
    {
        native |= MTLTextureUsageShaderRead;
    }
    if (hasUsage(usage, MetalTextureUsage::shader_write))
    {
        native |= MTLTextureUsageShaderWrite;
    }
    if (hasUsage(usage, MetalTextureUsage::render_target))
    {
        native |= MTLTextureUsageRenderTarget;
    }
    return native;
}

std::optional<MTLTextureType> nativeTextureType(MetalTextureKind kind) noexcept
{
    switch (kind)
    {
        case MetalTextureKind::texture_2d:
            return MTLTextureType2D;
        case MetalTextureKind::cube:
            return MTLTextureTypeCube;
        case MetalTextureKind::cube_array:
            return MTLTextureTypeCubeArray;
    }

    return std::nullopt;
}

std::uint32_t maximumMipLevels(std::uint32_t width, std::uint32_t height) noexcept
{
    std::uint32_t dimension = std::max(width, height);
    std::uint32_t levels    = 0;
    while (dimension != 0)
    {
        ++levels;
        dimension >>= 1U;
    }
    return levels;
}

NSString* nativeLabel(const std::string& label)
{
    if (label.empty())
    {
        return nil;
    }

    return [[NSString alloc] initWithBytes:label.data()
                                    length:label.size()
                                  encoding:NSUTF8StringEncoding];
}

bool validTextureShape(const MetalTextureDescriptor& descriptor) noexcept
{
    if (descriptor.width == 0 || descriptor.width > kMaximumTextureDimension ||
        descriptor.height == 0 || descriptor.height > kMaximumTextureDimension ||
        descriptor.mipLevels == 0 ||
        descriptor.mipLevels > maximumMipLevels(descriptor.width,
                                                descriptor.height))
    {
        return false;
    }

    switch (descriptor.kind)
    {
        case MetalTextureKind::texture_2d:
            return descriptor.arrayCount == 1;
        case MetalTextureKind::cube:
            return descriptor.width == descriptor.height &&
                   descriptor.arrayCount == 1;
        case MetalTextureKind::cube_array:
            return descriptor.width == descriptor.height &&
                   descriptor.arrayCount != 0 &&
                   descriptor.arrayCount <= kMaximumCubeArrayCount;
    }

    return false;
}

std::uint32_t physicalSliceCount(const MetalTextureDescriptor& descriptor) noexcept
{
    switch (descriptor.kind)
    {
        case MetalTextureKind::texture_2d:
            return 1;
        case MetalTextureKind::cube:
        case MetalTextureKind::cube_array:
            return descriptor.arrayCount * 6U;
    }

    return 0;
}

} // namespace

struct MetalPrivateBuffer::Impl
{
    Impl(id<MTLBuffer> native_buffer, std::size_t logical_size) :
        buffer(native_buffer),
        size(logical_size)
    {
    }

    __strong id<MTLBuffer> buffer;
    std::size_t            size = 0;
};

MetalPrivateBuffer::MetalPrivateBuffer(std::shared_ptr<const Impl> impl) noexcept :
    mImpl(std::move(impl))
{
}

std::optional<MetalPrivateBuffer> MetalPrivateBuffer::create(MetalDeviceHandle  device_handle,
                                                             std::size_t        size,
                                                             const std::string& label)
{
    if (!conformsToMetalProtocol(device_handle, @protocol(MTLDevice)) || size == 0 ||
        size > std::numeric_limits<NSUInteger>::max())
    {
        return std::nullopt;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)device_handle;
    if (size > device.maxBufferLength)
    {
        return std::nullopt;
    }

    id<MTLBuffer> buffer = [device newBufferWithLength:size
                                              options:MTLResourceStorageModePrivate];
    if (buffer == nil)
    {
        return std::nullopt;
    }

    NSString* converted_label = nativeLabel(label);
    if (converted_label != nil)
    {
        buffer.label = converted_label;
    }

    return MetalPrivateBuffer(std::make_shared<const Impl>(buffer, size));
}

bool MetalPrivateBuffer::valid() const noexcept
{
    return mImpl != nullptr && mImpl->buffer != nil &&
           mImpl->buffer.storageMode == MTLStorageModePrivate;
}

std::size_t MetalPrivateBuffer::size() const noexcept
{
    return valid() ? mImpl->size : 0;
}

MetalBufferHandle MetalPrivateBuffer::nativeHandle() const noexcept
{
    return valid() ? (__bridge void*)mImpl->buffer : nullptr;
}

struct MetalPrivateTexture::Impl
{
    Impl(id<MTLTexture> native_texture, MetalTextureDescriptor texture_descriptor) :
        texture(native_texture),
        descriptor(std::move(texture_descriptor))
    {
    }

    __strong id<MTLTexture>   texture;
    MetalTextureDescriptor descriptor;
};

MetalPrivateTexture::MetalPrivateTexture(std::shared_ptr<const Impl> impl) noexcept :
    mImpl(std::move(impl))
{
}

bool MetalPrivateTexture::valid() const noexcept
{
    if (mImpl == nullptr || mImpl->texture == nil)
    {
        return false;
    }

    const auto native_type = nativeTextureType(mImpl->descriptor.kind);
    const auto native_format = nativePixelFormat(mImpl->descriptor.format);
    const auto native_usage = nativeTextureUsage(mImpl->descriptor.usage);
    return native_type && native_format && native_usage &&
           validTextureShape(mImpl->descriptor) &&
           mImpl->texture.storageMode == MTLStorageModePrivate &&
           mImpl->texture.textureType == *native_type &&
           mImpl->texture.pixelFormat == *native_format &&
           mImpl->texture.width == mImpl->descriptor.width &&
           mImpl->texture.height == mImpl->descriptor.height &&
           mImpl->texture.depth == 1 && mImpl->texture.sampleCount == 1 &&
           mImpl->texture.mipmapLevelCount == mImpl->descriptor.mipLevels &&
           mImpl->texture.arrayLength == mImpl->descriptor.arrayCount &&
           (mImpl->texture.usage & *native_usage) == *native_usage;
}

MetalTextureKind MetalPrivateTexture::kind() const noexcept
{
    return valid() ? mImpl->descriptor.kind : MetalTextureKind::texture_2d;
}

PixelFormat MetalPrivateTexture::format() const noexcept
{
    return valid() ? mImpl->descriptor.format : PixelFormat::rgba8_unorm;
}

std::uint32_t MetalPrivateTexture::width() const noexcept
{
    return valid() ? mImpl->descriptor.width : 0;
}

std::uint32_t MetalPrivateTexture::height() const noexcept
{
    return valid() ? mImpl->descriptor.height : 0;
}

std::uint32_t MetalPrivateTexture::mipLevels() const noexcept
{
    return valid() ? mImpl->descriptor.mipLevels : 0;
}

std::uint32_t MetalPrivateTexture::arrayCount() const noexcept
{
    return valid() ? mImpl->descriptor.arrayCount : 0;
}

std::uint32_t MetalPrivateTexture::sliceCount() const noexcept
{
    return valid() ? physicalSliceCount(mImpl->descriptor) : 0;
}

MetalTextureUsage MetalPrivateTexture::usage() const noexcept
{
    return valid() ? mImpl->descriptor.usage : MetalTextureUsage::none;
}

std::optional<std::uint32_t>
MetalPrivateTexture::sliceForCubeFace(std::uint32_t cube_index,
                                      MetalCubeFace face) const noexcept
{
    if (!valid() || kind() == MetalTextureKind::texture_2d ||
        cube_index >= arrayCount())
    {
        return std::nullopt;
    }

    const auto face_index = static_cast<std::uint8_t>(face);
    if (face_index > static_cast<std::uint8_t>(MetalCubeFace::negative_z))
    {
        return std::nullopt;
    }
    return cube_index * 6U + face_index;
}

MetalTextureHandle MetalPrivateTexture::nativeHandle() const noexcept
{
    return valid() ? (__bridge void*)mImpl->texture : nullptr;
}

std::optional<MetalPrivateTexture>
createPrivateTexture(MetalDeviceHandle              device_handle,
                     const MetalTextureDescriptor& descriptor)
{
    const auto pixel_format = nativePixelFormat(descriptor.format);
    const auto usage        = nativeTextureUsage(descriptor.usage);
    const auto texture_type = nativeTextureType(descriptor.kind);
    NSString* converted_label = nativeLabel(descriptor.label);
    if (!conformsToMetalProtocol(device_handle, @protocol(MTLDevice)) || !pixel_format ||
        !usage || !texture_type || !validTextureShape(descriptor) ||
        (!descriptor.label.empty() && converted_label == nil) ||
        (descriptor.format == PixelFormat::depth32_float &&
         hasUsage(descriptor.usage, MetalTextureUsage::shader_write)))
    {
        return std::nullopt;
    }

    MTLTextureDescriptor* native_descriptor = [[MTLTextureDescriptor alloc] init];
    native_descriptor.textureType         = *texture_type;
    native_descriptor.pixelFormat         = *pixel_format;
    native_descriptor.width               = descriptor.width;
    native_descriptor.height              = descriptor.height;
    native_descriptor.depth               = 1;
    native_descriptor.mipmapLevelCount    = descriptor.mipLevels;
    native_descriptor.sampleCount         = 1;
    native_descriptor.arrayLength         = descriptor.arrayCount;
    native_descriptor.storageMode         = MTLStorageModePrivate;
    native_descriptor.hazardTrackingMode  = MTLHazardTrackingModeDefault;
    native_descriptor.usage               = *usage;

    id<MTLDevice> device = (__bridge id<MTLDevice>)device_handle;
    id<MTLTexture> texture = [device newTextureWithDescriptor:native_descriptor];
    if (texture == nil)
    {
        return std::nullopt;
    }

    if (converted_label != nil)
    {
        texture.label = converted_label;
    }

    return MetalPrivateTexture(
        std::make_shared<const MetalPrivateTexture::Impl>(texture, descriptor));
}

} // namespace firestorm::metal
