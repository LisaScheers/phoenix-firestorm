/**
 * @file llmetalformat.cpp
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

#include "llmetalformat.h"

#include <limits>

namespace firestorm::metal
{
namespace
{

    std::optional<std::size_t> checkedAdd(std::size_t lhs, std::size_t rhs) noexcept
    {
        if (rhs > std::numeric_limits<std::size_t>::max() - lhs)
        {
            return std::nullopt;
        }

        return lhs + rhs;
    }

    std::optional<std::size_t> checkedMultiply(std::size_t lhs, std::size_t rhs) noexcept
    {
        if (lhs != 0 && rhs > std::numeric_limits<std::size_t>::max() / lhs)
        {
            return std::nullopt;
        }

        return lhs * rhs;
    }

    std::optional<std::uint32_t> divideRoundUp(std::uint32_t value, std::uint32_t divisor) noexcept
    {
        if (value == 0 || divisor == 0)
        {
            return std::nullopt;
        }

        const std::uint32_t quotient = value / divisor;
        if (value % divisor == 0)
        {
            return quotient;
        }

        if (quotient == std::numeric_limits<std::uint32_t>::max())
        {
            return std::nullopt;
        }

        return quotient + 1;
    }

    std::optional<std::size_t> alignUp(std::size_t value, std::size_t alignment) noexcept
    {
        if (value == 0 || alignment == 0)
        {
            return std::nullopt;
        }

        const std::size_t remainder = value % alignment;
        if (remainder == 0)
        {
            return value;
        }

        return checkedAdd(value, alignment - remainder);
    }

} // namespace

std::optional<FormatInfo> formatInfo(PixelFormat format) noexcept
{
    switch (format)
    {
        case PixelFormat::bgra8_unorm:
        case PixelFormat::rgba8_unorm:
        case PixelFormat::rgba8_unorm_srgb:
        case PixelFormat::rg11b10_float:
        case PixelFormat::depth32_float:
            return FormatInfo{ 1, 1, 4 };

        case PixelFormat::rgba16_unorm:
        case PixelFormat::rgba16_float:
            return FormatInfo{ 1, 1, 8 };
    }

    return std::nullopt;
}

std::optional<SubresourceLayout> makeSubresourceLayout(PixelFormat   format,
                                                       std::uint32_t width,
                                                       std::uint32_t height,
                                                       std::size_t   rowAlignment) noexcept
{
    if (width == 0 || height == 0 || rowAlignment == 0)
    {
        return std::nullopt;
    }

    const auto info = formatInfo(format);
    if (!info || info->blockWidth == 0 || info->blockHeight == 0 || info->bytesPerBlock == 0)
    {
        return std::nullopt;
    }

    const auto blocks_wide = divideRoundUp(width, info->blockWidth);
    const auto blocks_high = divideRoundUp(height, info->blockHeight);
    if (!blocks_wide || !blocks_high)
    {
        return std::nullopt;
    }

    const auto unpadded_row = checkedMultiply(static_cast<std::size_t>(*blocks_wide), info->bytesPerBlock);
    if (!unpadded_row)
    {
        return std::nullopt;
    }

    const auto padded_row = alignUp(*unpadded_row, rowAlignment);
    if (!padded_row)
    {
        return std::nullopt;
    }

    const auto image_size = checkedMultiply(*padded_row, static_cast<std::size_t>(*blocks_high));
    if (!image_size)
    {
        return std::nullopt;
    }

    return SubresourceLayout{
        *blocks_wide,
        *blocks_high,
        *padded_row,
        *image_size,
    };
}

} // namespace firestorm::metal
