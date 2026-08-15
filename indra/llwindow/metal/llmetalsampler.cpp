/**
 * @file llmetalsampler.cpp
 * @brief Platform-neutral sampler validation and canonical cache keys.
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

#include "llmetalsampler.h"

namespace firestorm::metal
{
namespace
{

    constexpr bool valid(SamplerAddressMode mode) noexcept
    {
        switch (mode)
        {
            case SamplerAddressMode::repeat:
            case SamplerAddressMode::mirror_repeat:
            case SamplerAddressMode::clamp_to_edge:
                return true;
        }
        return false;
    }

    constexpr bool valid(SamplerFilter filter) noexcept
    {
        switch (filter)
        {
            case SamplerFilter::nearest:
            case SamplerFilter::linear:
                return true;
        }
        return false;
    }

    constexpr bool valid(SamplerMipFilter filter) noexcept
    {
        switch (filter)
        {
            case SamplerMipFilter::not_mipmapped:
            case SamplerMipFilter::nearest:
            case SamplerMipFilter::linear:
                return true;
        }
        return false;
    }

    void hashField(std::size_t& hash, std::size_t value) noexcept
    {
        // Explicit FNV-1a field mixing avoids treating padded object bytes as a key.
        constexpr std::size_t prime = 1099511628211ULL;
        hash ^= value;
        hash *= prime;
    }

} // namespace

std::size_t SamplerKeyHash::operator()(const SamplerKey& key) const noexcept
{
    std::size_t hash = 1469598103934665603ULL;
    hashField(hash, static_cast<std::size_t>(key.s));
    hashField(hash, static_cast<std::size_t>(key.t));
    hashField(hash, static_cast<std::size_t>(key.r));
    hashField(hash, static_cast<std::size_t>(key.min));
    hashField(hash, static_cast<std::size_t>(key.mag));
    hashField(hash, static_cast<std::size_t>(key.mip));
    hashField(hash, static_cast<std::size_t>(key.maxAnisotropy));
    return hash;
}

std::optional<SamplerKey> makeSamplerKey(const SamplerDesc& descriptor, std::uint32_t mip_level_count) noexcept
{
    if (!valid(descriptor.s) || !valid(descriptor.t) || !valid(descriptor.r) || !valid(descriptor.min) || !valid(descriptor.mag) ||
        !valid(descriptor.mip) || mip_level_count == 0 || descriptor.maxAnisotropy == 0 ||
        descriptor.maxAnisotropy > kMaximumSamplerAnisotropy)
    {
        return std::nullopt;
    }

    SamplerKey key{
        descriptor.s, descriptor.t, descriptor.r, descriptor.min, descriptor.mag, descriptor.mip, descriptor.maxAnisotropy,
    };
    if (mip_level_count == 1)
    {
        key.mip = SamplerMipFilter::not_mipmapped;
    }
    return key;
}

} // namespace firestorm::metal
