/**
 * @file llmetalsampler-objc.mm
 * @brief Native Metal sampler-state ownership and caching.
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

#include "llmetalsampler.h"

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

std::optional<MTLSamplerAddressMode> nativeAddressMode(SamplerAddressMode mode) noexcept
{
    switch (mode)
    {
        case SamplerAddressMode::repeat:
            return MTLSamplerAddressModeRepeat;
        case SamplerAddressMode::mirror_repeat:
            return MTLSamplerAddressModeMirrorRepeat;
        case SamplerAddressMode::clamp_to_edge:
            return MTLSamplerAddressModeClampToEdge;
    }
    return std::nullopt;
}

std::optional<MTLSamplerMinMagFilter> nativeFilter(SamplerFilter filter) noexcept
{
    switch (filter)
    {
        case SamplerFilter::nearest:
            return MTLSamplerMinMagFilterNearest;
        case SamplerFilter::linear:
            return MTLSamplerMinMagFilterLinear;
    }
    return std::nullopt;
}

std::optional<MTLSamplerMipFilter> nativeMipFilter(SamplerMipFilter filter) noexcept
{
    switch (filter)
    {
        case SamplerMipFilter::not_mipmapped:
            return MTLSamplerMipFilterNotMipmapped;
        case SamplerMipFilter::nearest:
            return MTLSamplerMipFilterNearest;
        case SamplerMipFilter::linear:
            return MTLSamplerMipFilterLinear;
    }
    return std::nullopt;
}

struct NativeSampler
{
    __strong id<MTLSamplerState> state;
};

} // namespace

struct MetalSamplerCache::Impl
{
    explicit Impl(id<MTLDevice> native_device) :
        device(native_device)
    {
    }

    __strong id<MTLDevice> device;
    std::unordered_map<SamplerKey, NativeSampler, SamplerKeyHash> entries;
    std::size_t hits   = 0;
    std::size_t misses = 0;
};

MetalSamplerCache::MetalSamplerCache(MetalDeviceHandle device)
{
    if (isMetalDevice(device))
    {
        mImpl = std::make_unique<Impl>((__bridge id<MTLDevice>)device);
    }
}

MetalSamplerCache::~MetalSamplerCache() = default;

bool MetalSamplerCache::valid() const noexcept
{
    return mImpl != nullptr && mImpl->device != nil;
}

std::optional<MetalSamplerHandle>
MetalSamplerCache::sampler(const SamplerDesc& descriptor,
                           std::uint32_t      mip_level_count)
{
    if (!valid())
    {
        return std::nullopt;
    }

    const auto key = makeSamplerKey(descriptor, mip_level_count);
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
    const auto s_address = nativeAddressMode(key->s);
    const auto t_address = nativeAddressMode(key->t);
    const auto r_address = nativeAddressMode(key->r);
    const auto min_filter = nativeFilter(key->min);
    const auto mag_filter = nativeFilter(key->mag);
    const auto mip_filter = nativeMipFilter(key->mip);
    if (!s_address || !t_address || !r_address || !min_filter || !mag_filter ||
        !mip_filter)
    {
        return std::nullopt;
    }

    MTLSamplerDescriptor* native_descriptor = [[MTLSamplerDescriptor alloc] init];
    native_descriptor.sAddressMode  = *s_address;
    native_descriptor.tAddressMode  = *t_address;
    native_descriptor.rAddressMode  = *r_address;
    native_descriptor.minFilter     = *min_filter;
    native_descriptor.magFilter     = *mag_filter;
    native_descriptor.mipFilter     = *mip_filter;
    native_descriptor.maxAnisotropy = key->maxAnisotropy;
    native_descriptor.normalizedCoordinates = YES;

    id<MTLSamplerState> state = [mImpl->device newSamplerStateWithDescriptor:native_descriptor];
    if (state == nil)
    {
        return std::nullopt;
    }

    const auto inserted = mImpl->entries.emplace(*key, NativeSampler{ state });
    if (!inserted.second)
    {
        return std::nullopt;
    }
    return (__bridge void*)inserted.first->second.state;
}

std::size_t MetalSamplerCache::hitCount() const noexcept
{
    return valid() ? mImpl->hits : 0;
}

std::size_t MetalSamplerCache::missCount() const noexcept
{
    return valid() ? mImpl->misses : 0;
}

std::size_t MetalSamplerCache::entryCount() const noexcept
{
    return valid() ? mImpl->entries.size() : 0;
}

} // namespace firestorm::metal
