/**
 * @file llmetalpipeline.h
 * @brief Canonical bounded attachment blend state and Metal pipeline families.
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

#pragma once

#include "llmetalformat.h"
#include "llmetalframecontext.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace firestorm::metal
{

/** Unretained bridges to native Metal objects. */
using MetalLibraryHandle        = void*;
using MetalRenderPipelineHandle = void*;

inline constexpr std::size_t kMaximumColorAttachments = 4;

enum class BlendOperation : std::uint8_t
{
    add,
    subtract,
    reverse_subtract,
    min,
    max,
};

enum class BlendFactor : std::uint8_t
{
    zero,
    one,
    source_color,
    one_minus_source_color,
    source_alpha,
    one_minus_source_alpha,
    destination_color,
    one_minus_destination_color,
    destination_alpha,
    one_minus_destination_alpha,
};

enum class ColorWriteMask : std::uint8_t
{
    none  = 0,
    red   = 1U << 0U,
    green = 1U << 1U,
    blue  = 1U << 2U,
    alpha = 1U << 3U,
    all   = (1U << 4U) - 1U,
};

constexpr ColorWriteMask operator|(ColorWriteMask lhs, ColorWriteMask rhs) noexcept
{
    return static_cast<ColorWriteMask>(static_cast<std::uint8_t>(lhs) | static_cast<std::uint8_t>(rhs));
}

constexpr ColorWriteMask operator&(ColorWriteMask lhs, ColorWriteMask rhs) noexcept
{
    return static_cast<ColorWriteMask>(static_cast<std::uint8_t>(lhs) & static_cast<std::uint8_t>(rhs));
}

constexpr bool hasColorWrite(ColorWriteMask value, ColorWriteMask channels) noexcept
{
    return (value & channels) != ColorWriteMask::none;
}

struct BlendAttachmentDesc
{
    bool           blendingEnabled        = false;
    BlendOperation rgbOperation           = BlendOperation::add;
    BlendFactor    sourceRGBFactor        = BlendFactor::one;
    BlendFactor    destinationRGBFactor   = BlendFactor::zero;
    BlendOperation alphaOperation         = BlendOperation::add;
    BlendFactor    sourceAlphaFactor      = BlendFactor::one;
    BlendFactor    destinationAlphaFactor = BlendFactor::zero;
    ColorWriteMask writeMask              = ColorWriteMask::all;
};

/** A validated blend attachment with every field unobservable in one color format canonicalized. */
struct BlendAttachmentKey
{
    bool           blendingEnabled        = false;
    BlendOperation rgbOperation           = BlendOperation::add;
    BlendFactor    sourceRGBFactor        = BlendFactor::one;
    BlendFactor    destinationRGBFactor   = BlendFactor::zero;
    BlendOperation alphaOperation         = BlendOperation::add;
    BlendFactor    sourceAlphaFactor      = BlendFactor::one;
    BlendFactor    destinationAlphaFactor = BlendFactor::zero;
    ColorWriteMask writeMask              = ColorWriteMask::all;
};

constexpr bool operator==(const BlendAttachmentKey& lhs, const BlendAttachmentKey& rhs) noexcept
{
    return lhs.blendingEnabled == rhs.blendingEnabled && lhs.rgbOperation == rhs.rgbOperation &&
           lhs.sourceRGBFactor == rhs.sourceRGBFactor && lhs.destinationRGBFactor == rhs.destinationRGBFactor &&
           lhs.alphaOperation == rhs.alphaOperation && lhs.sourceAlphaFactor == rhs.sourceAlphaFactor &&
           lhs.destinationAlphaFactor == rhs.destinationAlphaFactor && lhs.writeMask == rhs.writeMask;
}

constexpr bool operator!=(const BlendAttachmentKey& lhs, const BlendAttachmentKey& rhs) noexcept
{
    return !(lhs == rhs);
}

struct BlendAttachmentKeyHash
{
    std::size_t operator()(const BlendAttachmentKey& key) const noexcept;
};

/** Validates every field and the color format before canonicalizing fields that cannot affect output. */
std::optional<BlendAttachmentKey> makeBlendAttachmentKey(const BlendAttachmentDesc& descriptor,
                                                         PixelFormat                color_format) noexcept;

/**
 * Immutable identity shared by every entry in one pipeline family.
 *
 * This slice creates zero-to-four-color, one-sample pipelines for generated
 * vertices. Zero colors requires a depth attachment. The native pipeline
 * descriptor therefore has no vertex descriptor.
 */
struct MetalRenderPipelineFamilyDesc
{
    std::string                vertexFunction;
    std::string                fragmentFunction;
    std::vector<PixelFormat>   colorFormats{ PixelFormat::rgba8_unorm };
    std::optional<PixelFormat> depthFormat;
};

/**
 * Strongly owns one fixed shader/attachment family of native pipeline states.
 *
 * Only the ordered canonical blend attachments vary between entries. A request
 * must provide exactly one blend descriptor per family color format. Returned
 * handles are borrowed and remain valid until this cache is destroyed. Invalid
 * requests do not affect telemetry; a valid absent key is one miss even if
 * native allocation fails. Calls require external serialization, like sibling
 * caches.
 */
class MetalRenderPipelineFamilyCache final
{
public:
    MetalRenderPipelineFamilyCache(MetalDeviceHandle device, MetalLibraryHandle library, const MetalRenderPipelineFamilyDesc& descriptor);
    ~MetalRenderPipelineFamilyCache();

    MetalRenderPipelineFamilyCache(const MetalRenderPipelineFamilyCache&)            = delete;
    MetalRenderPipelineFamilyCache& operator=(const MetalRenderPipelineFamilyCache&) = delete;
    MetalRenderPipelineFamilyCache(MetalRenderPipelineFamilyCache&&)                 = delete;
    MetalRenderPipelineFamilyCache& operator=(MetalRenderPipelineFamilyCache&&)      = delete;

    bool valid() const noexcept;

    std::optional<MetalRenderPipelineHandle> pipeline(
        const std::vector<BlendAttachmentDesc>& descriptors);

    std::size_t hitCount() const noexcept;
    std::size_t missCount() const noexcept;
    std::size_t entryCount() const noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> mImpl;
};

} // namespace firestorm::metal
