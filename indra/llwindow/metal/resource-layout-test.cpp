/**
 * @file resource-layout-test.cpp
 * @brief Focused tests for Metal pixel-format and byte-layout contracts.
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

#include <array>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <optional>

namespace
{

int gFailures = 0;

void expect(bool condition, const char* expression, int line)
{
    if (!condition)
    {
        std::cerr << "FAIL line " << line << ": " << expression << '\n';
        ++gFailures;
    }
}

#define EXPECT(expression) expect(static_cast<bool>(expression), #expression, __LINE__)

using firestorm::metal::formatInfo;
using firestorm::metal::makeSubresourceLayout;
using firestorm::metal::PixelFormat;
using firestorm::metal::SubresourceLayout;

void testFormatInfo()
{
    struct Expectation
    {
        PixelFormat format;
        std::size_t bytesPerBlock;
    };

    constexpr std::array<Expectation, 7> expectations{ {
        { PixelFormat::bgra8_unorm, 4 },
        { PixelFormat::rgba8_unorm, 4 },
        { PixelFormat::rgba8_unorm_srgb, 4 },
        { PixelFormat::rgba16_unorm, 8 },
        { PixelFormat::rgba16_float, 8 },
        { PixelFormat::rg11b10_float, 4 },
        { PixelFormat::depth32_float, 4 },
    } };

    for (const Expectation expectation : expectations)
    {
        const auto info = formatInfo(expectation.format);
        EXPECT(info.has_value());
        if (info)
        {
            EXPECT(info->blockWidth == 1);
            EXPECT(info->blockHeight == 1);
            EXPECT(info->bytesPerBlock == expectation.bytesPerBlock);
        }

        const auto layout = makeSubresourceLayout(expectation.format, 1, 1, 1);
        EXPECT(layout == std::optional<SubresourceLayout>({ 1, 1, expectation.bytesPerBlock, expectation.bytesPerBlock }));
    }

    EXPECT(!formatInfo(static_cast<PixelFormat>(0xff)).has_value());
}

void testExactRgba8Layouts()
{
    const auto tightly_packed = makeSubresourceLayout(PixelFormat::rgba8_unorm, 3, 2, 1);
    EXPECT(tightly_packed == std::optional<SubresourceLayout>({ 3, 2, 12, 24 }));

    const auto aligned = makeSubresourceLayout(PixelFormat::rgba8_unorm, 3, 2, 256);
    EXPECT(aligned == std::optional<SubresourceLayout>({ 3, 2, 256, 512 }));

    const auto arbitrary_alignment = makeSubresourceLayout(PixelFormat::rgba8_unorm, 3, 2, 7);
    EXPECT(arbitrary_alignment == std::optional<SubresourceLayout>({ 3, 2, 14, 28 }));
}

void testInvalidInputsDoNotExposePartialLayouts()
{
    const auto baseline = makeSubresourceLayout(PixelFormat::rgba8_unorm, 3, 2, 1);
    EXPECT(baseline.has_value());
    if (!baseline)
    {
        return;
    }

    const SubresourceLayout retained = *baseline;

    EXPECT(!makeSubresourceLayout(PixelFormat::rgba8_unorm, 0, 2, 1).has_value());
    EXPECT(retained == *baseline);
    EXPECT(!makeSubresourceLayout(PixelFormat::rgba8_unorm, 3, 0, 1).has_value());
    EXPECT(retained == *baseline);
    EXPECT(!makeSubresourceLayout(PixelFormat::rgba8_unorm, 3, 2, 0).has_value());
    EXPECT(retained == *baseline);
    EXPECT(!makeSubresourceLayout(static_cast<PixelFormat>(0xff), 3, 2, 1).has_value());
    EXPECT(retained == *baseline);
}

void testCheckedMaximumEdges()
{
    constexpr std::uint32_t max_extent = std::numeric_limits<std::uint32_t>::max();
    constexpr std::size_t   max_size   = std::numeric_limits<std::size_t>::max();

    const auto max_alignment = makeSubresourceLayout(PixelFormat::rgba8_unorm, 1, 1, max_size);
    EXPECT(max_alignment == std::optional<SubresourceLayout>({ 1, 1, max_size, max_size }));

    EXPECT(!makeSubresourceLayout(PixelFormat::rgba8_unorm, 1, 2, max_size).has_value());

    const auto maximum_extents = makeSubresourceLayout(PixelFormat::rgba16_float, max_extent, max_extent, 1);
    EXPECT(!maximum_extents.has_value());

    const auto maximum_width = makeSubresourceLayout(PixelFormat::rgba16_float, max_extent, 1, 1);
    if (max_size / 8 >= max_extent)
    {
        EXPECT(maximum_width == std::optional<SubresourceLayout>({
                                    max_extent,
                                    1,
                                    static_cast<std::size_t>(max_extent) * 8,
                                    static_cast<std::size_t>(max_extent) * 8,
                                }));
    }
    else
    {
        EXPECT(!maximum_width.has_value());
    }
}

} // namespace

int main()
{
    testFormatInfo();
    testExactRgba8Layouts();
    testInvalidInputsDoNotExposePartialLayouts();
    testCheckedMaximumEdges();

    if (gFailures != 0)
    {
        std::cerr << gFailures << " resource layout contract test(s) failed\n";
        return EXIT_FAILURE;
    }

    std::cout << "PASS Metal resource layout contracts\n";
    return EXIT_SUCCESS;
}
