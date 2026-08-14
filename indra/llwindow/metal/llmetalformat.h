/**
 * @file llmetalformat.h
 * @brief CPU-side pixel-format and subresource-layout contracts.
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

#include <cstddef>
#include <cstdint>
#include <optional>

namespace firestorm::metal
{

/** Renderer-owned formats. Platform API mappings belong in platform code. */
enum class PixelFormat : std::uint8_t
{
    bgra8_unorm,
    rgba8_unorm,
    rgba16_unorm,
    rgba16_float,
    rg11b10_float,
    depth32_float,
};

struct FormatInfo
{
    std::uint32_t blockWidth    = 0;
    std::uint32_t blockHeight   = 0;
    std::size_t   bytesPerBlock = 0;
};

constexpr bool operator==(FormatInfo lhs, FormatInfo rhs) noexcept
{
    return lhs.blockWidth == rhs.blockWidth && lhs.blockHeight == rhs.blockHeight && lhs.bytesPerBlock == rhs.bytesPerBlock;
}

constexpr bool operator!=(FormatInfo lhs, FormatInfo rhs) noexcept
{
    return !(lhs == rhs);
}

/** Returns no value for an invalid PixelFormat representation. */
std::optional<FormatInfo> formatInfo(PixelFormat format) noexcept;

struct SubresourceLayout
{
    std::uint32_t blocksWide    = 0;
    std::uint32_t blocksHigh    = 0;
    std::size_t   bytesPerRow   = 0;
    std::size_t   bytesPerImage = 0;
};

constexpr bool operator==(SubresourceLayout lhs, SubresourceLayout rhs) noexcept
{
    return lhs.blocksWide == rhs.blocksWide && lhs.blocksHigh == rhs.blocksHigh && lhs.bytesPerRow == rhs.bytesPerRow &&
           lhs.bytesPerImage == rhs.bytesPerImage;
}

constexpr bool operator!=(SubresourceLayout lhs, SubresourceLayout rhs) noexcept
{
    return !(lhs == rhs);
}

/**
 * Computes a byte layout for one explicitly sized subresource.
 *
 * rowAlignment may be any positive value. bytesPerRow includes its padding,
 * and bytesPerImage includes the padded row size. This byte-count contract
 * intentionally assigns no top-to-bottom or bottom-to-top row orientation.
 * Invalid inputs and unrepresentable results return no value.
 */
std::optional<SubresourceLayout> makeSubresourceLayout(PixelFormat   format,
                                                       std::uint32_t width,
                                                       std::uint32_t height,
                                                       std::size_t   rowAlignment) noexcept;

} // namespace firestorm::metal
