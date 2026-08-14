/**
 * @file llmetalstate.h
 * @brief Typed depth and dynamic raster-state primitives for Metal.
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

#include "llmetalframecontext.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>

namespace firestorm::metal
{

/** Unretained bridges to native Metal objects. */
using MetalDepthStateHandle    = void*;
using MetalRenderEncoderHandle = void*;

enum class CompareFunction : std::uint8_t
{
    never,
    less,
    equal,
    less_equal,
    greater,
    not_equal,
    greater_equal,
    always,
};

struct DepthStateDesc
{
    CompareFunction compare      = CompareFunction::always;
    bool            writeEnabled = false;
};

/** A validated canonical cache key. */
struct DepthStateKey
{
    CompareFunction compare      = CompareFunction::always;
    bool            writeEnabled = false;
};

constexpr bool operator==(const DepthStateKey& lhs, const DepthStateKey& rhs) noexcept
{
    return lhs.compare == rhs.compare && lhs.writeEnabled == rhs.writeEnabled;
}

constexpr bool operator!=(const DepthStateKey& lhs, const DepthStateKey& rhs) noexcept
{
    return !(lhs == rhs);
}

struct DepthStateKeyHash
{
    std::size_t operator()(const DepthStateKey& key) const noexcept;
};

/** Rejects invalid enum representations before they reach the native API. */
std::optional<DepthStateKey> makeDepthStateKey(const DepthStateDesc& descriptor) noexcept;

/**
 * Strongly owns immutable native depth states, indexed by canonical keys.
 *
 * Returned handles are borrowed and remain valid until this cache is destroyed.
 * Invalid requests do not affect the counters. A valid absent key is one miss,
 * including when native allocation fails.
 */
class MetalDepthStateCache final
{
public:
    explicit MetalDepthStateCache(MetalDeviceHandle device);
    ~MetalDepthStateCache();

    MetalDepthStateCache(const MetalDepthStateCache&)            = delete;
    MetalDepthStateCache& operator=(const MetalDepthStateCache&) = delete;
    MetalDepthStateCache(MetalDepthStateCache&&)                 = delete;
    MetalDepthStateCache& operator=(MetalDepthStateCache&&)      = delete;

    bool valid() const noexcept;

    std::optional<MetalDepthStateHandle> depthState(const DepthStateDesc& descriptor);

    std::size_t hitCount() const noexcept;
    std::size_t missCount() const noexcept;
    std::size_t entryCount() const noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> mImpl;
};

enum class CullMode : std::uint8_t
{
    none,
    front,
    back,
};

enum class FrontFace : std::uint8_t
{
    clockwise,
    counter_clockwise,
};

struct RasterStateDesc
{
    CullMode  cullMode  = CullMode::none;
    FrontFace frontFace = FrontFace::clockwise;
};

/** Validates and applies both dynamic raster fields to a render encoder. */
bool applyRasterState(MetalRenderEncoderHandle encoder, const RasterStateDesc& descriptor) noexcept;

} // namespace firestorm::metal
