/**
 * @file llmetalpipeline.cpp
 * @brief Platform-neutral blend validation and canonical pipeline-family keys.
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

#include "llmetalpipeline.h"

namespace firestorm::metal
{
namespace
{

    constexpr ColorWriteMask RGB_WRITE_MASK = ColorWriteMask::red | ColorWriteMask::green | ColorWriteMask::blue;

    constexpr bool valid(BlendOperation operation) noexcept
    {
        switch (operation)
        {
            case BlendOperation::add:
            case BlendOperation::subtract:
            case BlendOperation::reverse_subtract:
            case BlendOperation::min:
            case BlendOperation::max:
                return true;
        }
        return false;
    }

    constexpr bool valid(BlendFactor factor) noexcept
    {
        switch (factor)
        {
            case BlendFactor::zero:
            case BlendFactor::one:
            case BlendFactor::source_color:
            case BlendFactor::one_minus_source_color:
            case BlendFactor::source_alpha:
            case BlendFactor::one_minus_source_alpha:
            case BlendFactor::destination_color:
            case BlendFactor::one_minus_destination_color:
            case BlendFactor::destination_alpha:
            case BlendFactor::one_minus_destination_alpha:
                return true;
        }
        return false;
    }

    constexpr bool valid(ColorWriteMask mask) noexcept
    {
        const auto raw = static_cast<std::uint8_t>(mask);
        const auto all = static_cast<std::uint8_t>(ColorWriteMask::all);
        return (raw & static_cast<std::uint8_t>(~all)) == 0;
    }

    constexpr bool ignoresFactors(BlendOperation operation) noexcept
    {
        return operation == BlendOperation::min || operation == BlendOperation::max;
    }

    constexpr BlendFactor canonicalAlphaFactor(BlendFactor factor) noexcept
    {
        switch (factor)
        {
            case BlendFactor::source_color:
                return BlendFactor::source_alpha;
            case BlendFactor::one_minus_source_color:
                return BlendFactor::one_minus_source_alpha;
            case BlendFactor::destination_color:
                return BlendFactor::destination_alpha;
            case BlendFactor::one_minus_destination_color:
                return BlendFactor::one_minus_destination_alpha;
            case BlendFactor::zero:
            case BlendFactor::one:
            case BlendFactor::source_alpha:
            case BlendFactor::one_minus_source_alpha:
            case BlendFactor::destination_alpha:
            case BlendFactor::one_minus_destination_alpha:
                return factor;
        }
        return factor;
    }

    void resetRGB(BlendAttachmentKey& key) noexcept
    {
        key.rgbOperation         = BlendOperation::add;
        key.sourceRGBFactor      = BlendFactor::one;
        key.destinationRGBFactor = BlendFactor::zero;
    }

    void resetAlpha(BlendAttachmentKey& key) noexcept
    {
        key.alphaOperation         = BlendOperation::add;
        key.sourceAlphaFactor      = BlendFactor::one;
        key.destinationAlphaFactor = BlendFactor::zero;
    }

    void hashField(std::size_t& hash, std::size_t value) noexcept
    {
        constexpr std::size_t prime = 1099511628211ULL;
        hash ^= value;
        hash *= prime;
    }

} // namespace

std::size_t BlendAttachmentKeyHash::operator()(const BlendAttachmentKey& key) const noexcept
{
    std::size_t hash = 1469598103934665603ULL;
    hashField(hash, key.blendingEnabled ? 1U : 0U);
    hashField(hash, static_cast<std::size_t>(key.rgbOperation));
    hashField(hash, static_cast<std::size_t>(key.sourceRGBFactor));
    hashField(hash, static_cast<std::size_t>(key.destinationRGBFactor));
    hashField(hash, static_cast<std::size_t>(key.alphaOperation));
    hashField(hash, static_cast<std::size_t>(key.sourceAlphaFactor));
    hashField(hash, static_cast<std::size_t>(key.destinationAlphaFactor));
    hashField(hash, static_cast<std::size_t>(key.writeMask));
    return hash;
}

std::optional<BlendAttachmentKey> makeBlendAttachmentKey(const BlendAttachmentDesc& descriptor) noexcept
{
    if (!valid(descriptor.rgbOperation) || !valid(descriptor.sourceRGBFactor) || !valid(descriptor.destinationRGBFactor) ||
        !valid(descriptor.alphaOperation) || !valid(descriptor.sourceAlphaFactor) || !valid(descriptor.destinationAlphaFactor) ||
        !valid(descriptor.writeMask))
    {
        return std::nullopt;
    }

    BlendAttachmentKey key{
        descriptor.blendingEnabled, descriptor.rgbOperation,      descriptor.sourceRGBFactor,        descriptor.destinationRGBFactor,
        descriptor.alphaOperation,  descriptor.sourceAlphaFactor, descriptor.destinationAlphaFactor, descriptor.writeMask,
    };

    if (!key.blendingEnabled || key.writeMask == ColorWriteMask::none)
    {
        key.blendingEnabled = false;
        resetRGB(key);
        resetAlpha(key);
        return key;
    }

    if (!hasColorWrite(key.writeMask, RGB_WRITE_MASK))
    {
        resetRGB(key);
    }
    else if (ignoresFactors(key.rgbOperation))
    {
        key.sourceRGBFactor      = BlendFactor::one;
        key.destinationRGBFactor = BlendFactor::one;
    }

    if (!hasColorWrite(key.writeMask, ColorWriteMask::alpha))
    {
        resetAlpha(key);
    }
    else if (ignoresFactors(key.alphaOperation))
    {
        key.sourceAlphaFactor      = BlendFactor::one;
        key.destinationAlphaFactor = BlendFactor::one;
    }
    else
    {
        key.sourceAlphaFactor      = canonicalAlphaFactor(key.sourceAlphaFactor);
        key.destinationAlphaFactor = canonicalAlphaFactor(key.destinationAlphaFactor);
    }

    return key;
}

} // namespace firestorm::metal
