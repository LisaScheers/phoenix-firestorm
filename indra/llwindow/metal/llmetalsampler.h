/**
 * @file llmetalsampler.h
 * @brief Canonical sampler descriptors and a small native Metal sampler cache.
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

/** Unretained bridge to an id<MTLSamplerState>. */
using MetalSamplerHandle = void*;

enum class SamplerAddressMode : std::uint8_t
{
    repeat,
    mirror_repeat,
    clamp_to_edge,
};

enum class SamplerFilter : std::uint8_t
{
    nearest,
    linear,
};

enum class SamplerMipFilter : std::uint8_t
{
    not_mipmapped,
    nearest,
    linear,
};

struct SamplerDesc
{
    SamplerAddressMode s             = SamplerAddressMode::clamp_to_edge;
    SamplerAddressMode t             = SamplerAddressMode::clamp_to_edge;
    SamplerAddressMode r             = SamplerAddressMode::clamp_to_edge;
    SamplerFilter      min           = SamplerFilter::nearest;
    SamplerFilter      mag           = SamplerFilter::nearest;
    SamplerMipFilter   mip           = SamplerMipFilter::not_mipmapped;
    std::uint32_t      maxAnisotropy = 1;
};

/** Valid Metal sampler anisotropy is the inclusive range 1 through 16. */
inline constexpr std::uint32_t kMaximumSamplerAnisotropy = 16;

/** A validated, canonical cache key. */
struct SamplerKey
{
    SamplerAddressMode s             = SamplerAddressMode::clamp_to_edge;
    SamplerAddressMode t             = SamplerAddressMode::clamp_to_edge;
    SamplerAddressMode r             = SamplerAddressMode::clamp_to_edge;
    SamplerFilter      min           = SamplerFilter::nearest;
    SamplerFilter      mag           = SamplerFilter::nearest;
    SamplerMipFilter   mip           = SamplerMipFilter::not_mipmapped;
    std::uint32_t      maxAnisotropy = 1;
};

constexpr bool operator==(const SamplerKey& lhs, const SamplerKey& rhs) noexcept
{
    return lhs.s == rhs.s && lhs.t == rhs.t && lhs.r == rhs.r && lhs.min == rhs.min && lhs.mag == rhs.mag && lhs.mip == rhs.mip &&
           lhs.maxAnisotropy == rhs.maxAnisotropy;
}

constexpr bool operator!=(const SamplerKey& lhs, const SamplerKey& rhs) noexcept
{
    return !(lhs == rhs);
}

struct SamplerKeyHash
{
    std::size_t operator()(const SamplerKey& key) const noexcept;
};

/**
 * Validates and canonicalizes a sampler request for a concrete texture.
 *
 * One-level textures always use not_mipmapped in the returned key, so requests
 * that can have no observable mip-filter difference share one native state.
 */
std::optional<SamplerKey> makeSamplerKey(const SamplerDesc& descriptor, std::uint32_t mip_level_count) noexcept;

/**
 * Strongly owns immutable native sampler states, indexed by canonical keys.
 *
 * A returned handle is borrowed and remains valid until this cache is
 * destroyed. Invalid requests do not affect the hit or miss counters. A valid
 * key absent from the cache is one miss, including if native allocation fails.
 */
class MetalSamplerCache final
{
public:
    explicit MetalSamplerCache(MetalDeviceHandle device);
    ~MetalSamplerCache();

    MetalSamplerCache(const MetalSamplerCache&)            = delete;
    MetalSamplerCache& operator=(const MetalSamplerCache&) = delete;
    MetalSamplerCache(MetalSamplerCache&&)                 = delete;
    MetalSamplerCache& operator=(MetalSamplerCache&&)      = delete;

    bool valid() const noexcept;

    std::optional<MetalSamplerHandle> sampler(const SamplerDesc& descriptor, std::uint32_t mip_level_count);

    std::size_t hitCount() const noexcept;
    std::size_t missCount() const noexcept;
    std::size_t entryCount() const noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> mImpl;
};

} // namespace firestorm::metal
