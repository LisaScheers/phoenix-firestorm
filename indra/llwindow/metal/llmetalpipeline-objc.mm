/**
 * @file llmetalpipeline-objc.mm
 * @brief Native ownership for one-color generated-vertex Metal pipeline families.
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

#include <optional>
#include <unordered_map>

namespace firestorm::metal
{
namespace
{

bool isMetalDevice(MetalDeviceHandle handle)
{
    id object = (__bridge id)handle;
    return object != nil && [object conformsToProtocol:@protocol(MTLDevice)];
}

bool isMetalLibrary(MetalLibraryHandle handle)
{
    id object = (__bridge id)handle;
    return object != nil && [object conformsToProtocol:@protocol(MTLLibrary)];
}

NSString* nativeString(const std::string& value)
{
    return [[NSString alloc] initWithBytes:value.data()
                                    length:value.size()
                                  encoding:NSUTF8StringEncoding];
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

std::optional<MTLBlendOperation>
nativeBlendOperation(BlendOperation operation) noexcept
{
    switch (operation)
    {
        case BlendOperation::add:
            return MTLBlendOperationAdd;
        case BlendOperation::subtract:
            return MTLBlendOperationSubtract;
        case BlendOperation::reverse_subtract:
            return MTLBlendOperationReverseSubtract;
        case BlendOperation::min:
            return MTLBlendOperationMin;
        case BlendOperation::max:
            return MTLBlendOperationMax;
    }
    return std::nullopt;
}

std::optional<MTLBlendFactor> nativeBlendFactor(BlendFactor factor) noexcept
{
    switch (factor)
    {
        case BlendFactor::zero:
            return MTLBlendFactorZero;
        case BlendFactor::one:
            return MTLBlendFactorOne;
        case BlendFactor::source_color:
            return MTLBlendFactorSourceColor;
        case BlendFactor::one_minus_source_color:
            return MTLBlendFactorOneMinusSourceColor;
        case BlendFactor::source_alpha:
            return MTLBlendFactorSourceAlpha;
        case BlendFactor::one_minus_source_alpha:
            return MTLBlendFactorOneMinusSourceAlpha;
        case BlendFactor::destination_color:
            return MTLBlendFactorDestinationColor;
        case BlendFactor::one_minus_destination_color:
            return MTLBlendFactorOneMinusDestinationColor;
        case BlendFactor::destination_alpha:
            return MTLBlendFactorDestinationAlpha;
        case BlendFactor::one_minus_destination_alpha:
            return MTLBlendFactorOneMinusDestinationAlpha;
    }
    return std::nullopt;
}

MTLColorWriteMask nativeWriteMask(ColorWriteMask mask) noexcept
{
    MTLColorWriteMask native = MTLColorWriteMaskNone;
    if (hasColorWrite(mask, ColorWriteMask::red))
    {
        native |= MTLColorWriteMaskRed;
    }
    if (hasColorWrite(mask, ColorWriteMask::green))
    {
        native |= MTLColorWriteMaskGreen;
    }
    if (hasColorWrite(mask, ColorWriteMask::blue))
    {
        native |= MTLColorWriteMaskBlue;
    }
    if (hasColorWrite(mask, ColorWriteMask::alpha))
    {
        native |= MTLColorWriteMaskAlpha;
    }
    return native;
}

struct NativePipeline
{
    __strong id<MTLRenderPipelineState> state;
};

} // namespace

struct MetalRenderPipelineFamilyCache::Impl
{
    Impl(id<MTLDevice>                  native_device,
         id<MTLLibrary>                 native_library,
         id<MTLFunction>                native_vertex,
         id<MTLFunction>                native_fragment,
         PixelFormat                    source_color_format,
         MTLPixelFormat                 native_color_format,
         std::optional<MTLPixelFormat>  native_depth_format) :
        device(native_device),
        library(native_library),
        vertex(native_vertex),
        fragment(native_fragment),
        sourceColorFormat(source_color_format),
        colorFormat(native_color_format),
        depthFormat(native_depth_format)
    {
    }

    __strong id<MTLDevice> device;
    __strong id<MTLLibrary> library;
    __strong id<MTLFunction> vertex;
    __strong id<MTLFunction> fragment;
    PixelFormat sourceColorFormat;
    MTLPixelFormat colorFormat;
    std::optional<MTLPixelFormat> depthFormat;
    std::unordered_map<BlendAttachmentKey,
                       NativePipeline,
                       BlendAttachmentKeyHash> entries;
    std::size_t hits   = 0;
    std::size_t misses = 0;
};

MetalRenderPipelineFamilyCache::MetalRenderPipelineFamilyCache(
    MetalDeviceHandle                    device,
    MetalLibraryHandle                   library,
    const MetalRenderPipelineFamilyDesc& descriptor)
{
    if (!isMetalDevice(device) || !isMetalLibrary(library) ||
        descriptor.vertexFunction.empty() ||
        descriptor.fragmentFunction.empty() ||
        !isColorFormat(descriptor.colorFormat) ||
        (descriptor.depthFormat &&
         !isDepthFormat(*descriptor.depthFormat)))
    {
        return;
    }

    id<MTLDevice> native_device = (__bridge id<MTLDevice>)device;
    id<MTLLibrary> native_library = (__bridge id<MTLLibrary>)library;
    if (native_library.device != native_device)
    {
        return;
    }

    const auto color_format = nativePixelFormat(descriptor.colorFormat);
    const auto depth_format = descriptor.depthFormat
        ? nativePixelFormat(*descriptor.depthFormat)
        : std::optional<MTLPixelFormat>{};
    if (!color_format || (descriptor.depthFormat && !depth_format))
    {
        return;
    }

    NSString* vertex_name = nativeString(descriptor.vertexFunction);
    NSString* fragment_name = nativeString(descriptor.fragmentFunction);
    if (vertex_name == nil || fragment_name == nil)
    {
        return;
    }

    id<MTLFunction> vertex =
        [native_library newFunctionWithName:vertex_name];
    id<MTLFunction> fragment =
        [native_library newFunctionWithName:fragment_name];
    if (vertex == nil || fragment == nil ||
        vertex.functionType != MTLFunctionTypeVertex ||
        fragment.functionType != MTLFunctionTypeFragment)
    {
        return;
    }

    mImpl = std::make_unique<Impl>(native_device,
                                   native_library,
                                   vertex,
                                   fragment,
                                   descriptor.colorFormat,
                                   *color_format,
                                   depth_format);
}

MetalRenderPipelineFamilyCache::~MetalRenderPipelineFamilyCache() = default;

bool MetalRenderPipelineFamilyCache::valid() const noexcept
{
    return mImpl != nullptr && mImpl->device != nil &&
           mImpl->library != nil && mImpl->vertex != nil &&
           mImpl->fragment != nil;
}

std::optional<MetalRenderPipelineHandle>
MetalRenderPipelineFamilyCache::pipeline(
    const BlendAttachmentDesc& descriptor)
{
    if (!valid())
    {
        return std::nullopt;
    }

    const auto key = makeBlendAttachmentKey(descriptor,
                                            mImpl->sourceColorFormat);
    if (!key)
    {
        return std::nullopt;
    }

    const auto existing = mImpl->entries.find(*key);
    if (existing != mImpl->entries.end())
    {
        ++mImpl->hits;
        return (__bridge void*)existing->second.state;
    }

    ++mImpl->misses;
    const auto rgb_operation = nativeBlendOperation(key->rgbOperation);
    const auto source_rgb = nativeBlendFactor(key->sourceRGBFactor);
    const auto destination_rgb =
        nativeBlendFactor(key->destinationRGBFactor);
    const auto alpha_operation = nativeBlendOperation(key->alphaOperation);
    const auto source_alpha = nativeBlendFactor(key->sourceAlphaFactor);
    const auto destination_alpha =
        nativeBlendFactor(key->destinationAlphaFactor);
    if (!rgb_operation || !source_rgb || !destination_rgb ||
        !alpha_operation || !source_alpha || !destination_alpha)
    {
        return std::nullopt;
    }

    MTLRenderPipelineDescriptor* native_descriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    native_descriptor.label = @"Firestorm cached render pipeline family entry";
    native_descriptor.vertexFunction = mImpl->vertex;
    native_descriptor.fragmentFunction = mImpl->fragment;
    native_descriptor.rasterSampleCount = 1;
    native_descriptor.vertexDescriptor = nil;
    native_descriptor.depthAttachmentPixelFormat = mImpl->depthFormat
        ? *mImpl->depthFormat
        : MTLPixelFormatInvalid;

    MTLRenderPipelineColorAttachmentDescriptor* attachment =
        native_descriptor.colorAttachments[0];
    attachment.pixelFormat = mImpl->colorFormat;
    attachment.blendingEnabled = key->blendingEnabled;
    attachment.rgbBlendOperation = *rgb_operation;
    attachment.sourceRGBBlendFactor = *source_rgb;
    attachment.destinationRGBBlendFactor = *destination_rgb;
    attachment.alphaBlendOperation = *alpha_operation;
    attachment.sourceAlphaBlendFactor = *source_alpha;
    attachment.destinationAlphaBlendFactor = *destination_alpha;
    attachment.writeMask = nativeWriteMask(key->writeMask);

    NSError* error = nil;
    id<MTLRenderPipelineState> pipeline =
        [mImpl->device newRenderPipelineStateWithDescriptor:native_descriptor
                                                     error:&error];
    if (pipeline == nil)
    {
        return std::nullopt;
    }

    const auto inserted =
        mImpl->entries.emplace(*key, NativePipeline{ pipeline });
    if (!inserted.second)
    {
        return std::nullopt;
    }
    return (__bridge void*)inserted.first->second.state;
}

std::size_t MetalRenderPipelineFamilyCache::hitCount() const noexcept
{
    return valid() ? mImpl->hits : 0;
}

std::size_t MetalRenderPipelineFamilyCache::missCount() const noexcept
{
    return valid() ? mImpl->misses : 0;
}

std::size_t MetalRenderPipelineFamilyCache::entryCount() const noexcept
{
    return valid() ? mImpl->entries.size() : 0;
}

} // namespace firestorm::metal
