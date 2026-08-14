/**
 * @file llmetalpipeline-objc.mm
 * @brief Native ownership for bounded generated-vertex Metal pipeline families.
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

#include <array>
#include <optional>
#include <unordered_map>
#include <vector>

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

constexpr bool isColorFormat(PixelFormat format) noexcept
{
    switch (format)
    {
        case PixelFormat::bgra8_unorm:
        case PixelFormat::rgba8_unorm:
        case PixelFormat::rgba8_unorm_srgb:
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
        case PixelFormat::rgba8_unorm_srgb:
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

struct PipelineKey
{
    std::size_t count = 0;
    std::array<BlendAttachmentKey, kMaximumColorAttachments> attachments{};
};

bool operator==(const PipelineKey& lhs, const PipelineKey& rhs) noexcept
{
    if (lhs.count != rhs.count)
    {
        return false;
    }
    for (std::size_t index = 0; index < lhs.count; ++index)
    {
        if (lhs.attachments[index] != rhs.attachments[index])
        {
            return false;
        }
    }
    return true;
}

struct PipelineKeyHash
{
    std::size_t operator()(const PipelineKey& key) const noexcept
    {
        std::size_t hash = key.count;
        for (std::size_t index = 0; index < key.count; ++index)
        {
            const std::size_t attachment_hash =
                BlendAttachmentKeyHash{}(key.attachments[index]);
            hash ^= attachment_hash + 0x9e3779b97f4a7c15ULL +
                    (hash << 6U) + (hash >> 2U);
        }
        return hash;
    }
};

struct NativeBlendState
{
    MTLBlendOperation rgbOperation;
    MTLBlendFactor sourceRGB;
    MTLBlendFactor destinationRGB;
    MTLBlendOperation alphaOperation;
    MTLBlendFactor sourceAlpha;
    MTLBlendFactor destinationAlpha;
};

} // namespace

struct MetalRenderPipelineFamilyCache::Impl
{
    Impl(id<MTLDevice>                  native_device,
         id<MTLLibrary>                 native_library,
         id<MTLFunction>                native_vertex,
         id<MTLFunction>                native_fragment,
         std::vector<PixelFormat>        source_color_formats,
         std::vector<MTLPixelFormat>     native_color_formats,
         std::optional<MTLPixelFormat>  native_depth_format) :
        device(native_device),
        library(native_library),
        vertex(native_vertex),
        fragment(native_fragment),
        sourceColorFormats(std::move(source_color_formats)),
        colorFormats(std::move(native_color_formats)),
        depthFormat(native_depth_format)
    {
    }

    __strong id<MTLDevice> device;
    __strong id<MTLLibrary> library;
    __strong id<MTLFunction> vertex;
    __strong id<MTLFunction> fragment;
    std::vector<PixelFormat> sourceColorFormats;
    std::vector<MTLPixelFormat> colorFormats;
    std::optional<MTLPixelFormat> depthFormat;
    std::unordered_map<PipelineKey,
                       NativePipeline,
                       PipelineKeyHash> entries;
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
        descriptor.colorFormats.size() > kMaximumColorAttachments ||
        (descriptor.colorFormats.empty() && !descriptor.depthFormat) ||
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

    std::vector<MTLPixelFormat> color_formats;
    color_formats.reserve(descriptor.colorFormats.size());
    for (PixelFormat format : descriptor.colorFormats)
    {
        const auto native_format = nativePixelFormat(format);
        if (!isColorFormat(format) || !native_format)
        {
            return;
        }
        color_formats.push_back(*native_format);
    }
    const auto depth_format = descriptor.depthFormat
        ? nativePixelFormat(*descriptor.depthFormat)
        : std::optional<MTLPixelFormat>{};
    if (descriptor.depthFormat && !depth_format)
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
                                   descriptor.colorFormats,
                                   std::move(color_formats),
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
    const std::vector<BlendAttachmentDesc>& descriptors)
{
    if (!valid() || descriptors.size() != mImpl->sourceColorFormats.size())
    {
        return std::nullopt;
    }

    PipelineKey key;
    key.count = descriptors.size();
    std::array<NativeBlendState, kMaximumColorAttachments> native_states{};
    for (std::size_t index = 0; index < descriptors.size(); ++index)
    {
        const auto attachment_key = makeBlendAttachmentKey(
            descriptors[index], mImpl->sourceColorFormats[index]);
        if (!attachment_key)
        {
            return std::nullopt;
        }
        key.attachments[index] = *attachment_key;

        const auto rgb_operation =
            nativeBlendOperation(attachment_key->rgbOperation);
        const auto source_rgb =
            nativeBlendFactor(attachment_key->sourceRGBFactor);
        const auto destination_rgb =
            nativeBlendFactor(attachment_key->destinationRGBFactor);
        const auto alpha_operation =
            nativeBlendOperation(attachment_key->alphaOperation);
        const auto source_alpha =
            nativeBlendFactor(attachment_key->sourceAlphaFactor);
        const auto destination_alpha =
            nativeBlendFactor(attachment_key->destinationAlphaFactor);
        if (!rgb_operation || !source_rgb || !destination_rgb ||
            !alpha_operation || !source_alpha || !destination_alpha)
        {
            return std::nullopt;
        }
        native_states[index] = NativeBlendState{
            *rgb_operation,
            *source_rgb,
            *destination_rgb,
            *alpha_operation,
            *source_alpha,
            *destination_alpha,
        };
    }

    const auto existing = mImpl->entries.find(key);
    if (existing != mImpl->entries.end())
    {
        ++mImpl->hits;
        return (__bridge void*)existing->second.state;
    }

    ++mImpl->misses;
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

    for (std::size_t index = 0; index < key.count; ++index)
    {
        MTLRenderPipelineColorAttachmentDescriptor* attachment =
            native_descriptor.colorAttachments[index];
        const BlendAttachmentKey& attachment_key = key.attachments[index];
        const NativeBlendState& native_state = native_states[index];
        attachment.pixelFormat = mImpl->colorFormats[index];
        attachment.blendingEnabled = attachment_key.blendingEnabled;
        attachment.rgbBlendOperation = native_state.rgbOperation;
        attachment.sourceRGBBlendFactor = native_state.sourceRGB;
        attachment.destinationRGBBlendFactor = native_state.destinationRGB;
        attachment.alphaBlendOperation = native_state.alphaOperation;
        attachment.sourceAlphaBlendFactor = native_state.sourceAlpha;
        attachment.destinationAlphaBlendFactor = native_state.destinationAlpha;
        attachment.writeMask = nativeWriteMask(attachment_key.writeMask);
    }

    NSError* error = nil;
    id<MTLRenderPipelineState> pipeline =
        [mImpl->device newRenderPipelineStateWithDescriptor:native_descriptor
                                                     error:&error];
    if (pipeline == nil)
    {
        return std::nullopt;
    }

    const auto inserted =
        mImpl->entries.emplace(key, NativePipeline{ pipeline });
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
