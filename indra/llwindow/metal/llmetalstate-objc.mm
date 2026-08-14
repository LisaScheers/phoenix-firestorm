/**
 * @file llmetalstate-objc.mm
 * @brief Native Metal depth-state ownership and dynamic raster mapping.
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

#include "llmetalstate.h"

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

bool isRenderEncoder(MetalRenderEncoderHandle handle)
{
    id object = (__bridge id)handle;
    return object != nil &&
           [object conformsToProtocol:@protocol(MTLRenderCommandEncoder)];
}

constexpr bool valid(CompareFunction function) noexcept
{
    switch (function)
    {
        case CompareFunction::never:
        case CompareFunction::less:
        case CompareFunction::equal:
        case CompareFunction::less_equal:
        case CompareFunction::greater:
        case CompareFunction::not_equal:
        case CompareFunction::greater_equal:
        case CompareFunction::always:
            return true;
    }
    return false;
}

std::optional<MTLCompareFunction>
nativeCompareFunction(CompareFunction function) noexcept
{
    switch (function)
    {
        case CompareFunction::never:
            return MTLCompareFunctionNever;
        case CompareFunction::less:
            return MTLCompareFunctionLess;
        case CompareFunction::equal:
            return MTLCompareFunctionEqual;
        case CompareFunction::less_equal:
            return MTLCompareFunctionLessEqual;
        case CompareFunction::greater:
            return MTLCompareFunctionGreater;
        case CompareFunction::not_equal:
            return MTLCompareFunctionNotEqual;
        case CompareFunction::greater_equal:
            return MTLCompareFunctionGreaterEqual;
        case CompareFunction::always:
            return MTLCompareFunctionAlways;
    }
    return std::nullopt;
}

std::optional<MTLCullMode> nativeCullMode(CullMode mode) noexcept
{
    switch (mode)
    {
        case CullMode::none:
            return MTLCullModeNone;
        case CullMode::front:
            return MTLCullModeFront;
        case CullMode::back:
            return MTLCullModeBack;
    }
    return std::nullopt;
}

std::optional<MTLWinding> nativeFrontFace(FrontFace face) noexcept
{
    switch (face)
    {
        case FrontFace::clockwise:
            return MTLWindingClockwise;
        case FrontFace::counter_clockwise:
            return MTLWindingCounterClockwise;
    }
    return std::nullopt;
}

void hashField(std::size_t& hash, std::size_t value) noexcept
{
    constexpr std::size_t prime = 1099511628211ULL;
    hash ^= value;
    hash *= prime;
}

struct NativeDepthState
{
    __strong id<MTLDepthStencilState> state;
};

} // namespace

std::size_t DepthStateKeyHash::operator()(const DepthStateKey& key) const noexcept
{
    std::size_t hash = 1469598103934665603ULL;
    hashField(hash, static_cast<std::size_t>(key.compare));
    hashField(hash, key.writeEnabled ? 1U : 0U);
    return hash;
}

std::optional<DepthStateKey>
makeDepthStateKey(const DepthStateDesc& descriptor) noexcept
{
    if (!valid(descriptor.compare))
    {
        return std::nullopt;
    }
    return DepthStateKey{ descriptor.compare, descriptor.writeEnabled };
}

struct MetalDepthStateCache::Impl
{
    explicit Impl(id<MTLDevice> native_device) :
        device(native_device)
    {
    }

    __strong id<MTLDevice> device;
    std::unordered_map<DepthStateKey, NativeDepthState, DepthStateKeyHash>
        entries;
    std::size_t hits   = 0;
    std::size_t misses = 0;
};

MetalDepthStateCache::MetalDepthStateCache(MetalDeviceHandle device)
{
    if (isMetalDevice(device))
    {
        mImpl = std::make_unique<Impl>((__bridge id<MTLDevice>)device);
    }
}

MetalDepthStateCache::~MetalDepthStateCache() = default;

bool MetalDepthStateCache::valid() const noexcept
{
    return mImpl != nullptr && mImpl->device != nil;
}

std::optional<MetalDepthStateHandle>
MetalDepthStateCache::depthState(const DepthStateDesc& descriptor)
{
    if (!valid())
    {
        return std::nullopt;
    }

    const auto key = makeDepthStateKey(descriptor);
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
    const auto comparison = nativeCompareFunction(key->compare);
    if (!comparison)
    {
        return std::nullopt;
    }

    MTLDepthStencilDescriptor* native_descriptor =
        [[MTLDepthStencilDescriptor alloc] init];
    native_descriptor.label = @"Firestorm cached depth state";
    native_descriptor.depthCompareFunction = *comparison;
    native_descriptor.depthWriteEnabled = key->writeEnabled;

    id<MTLDepthStencilState> state =
        [mImpl->device newDepthStencilStateWithDescriptor:native_descriptor];
    if (state == nil)
    {
        return std::nullopt;
    }

    const auto inserted = mImpl->entries.emplace(*key,
                                                  NativeDepthState{ state });
    if (!inserted.second)
    {
        return std::nullopt;
    }
    return (__bridge void*)inserted.first->second.state;
}

std::size_t MetalDepthStateCache::hitCount() const noexcept
{
    return valid() ? mImpl->hits : 0;
}

std::size_t MetalDepthStateCache::missCount() const noexcept
{
    return valid() ? mImpl->misses : 0;
}

std::size_t MetalDepthStateCache::entryCount() const noexcept
{
    return valid() ? mImpl->entries.size() : 0;
}

bool applyRasterState(MetalRenderEncoderHandle encoder_handle,
                      const RasterStateDesc&   descriptor) noexcept
{
    if (!isRenderEncoder(encoder_handle))
    {
        return false;
    }

    const auto cull_mode = nativeCullMode(descriptor.cullMode);
    const auto front_face = nativeFrontFace(descriptor.frontFace);
    if (!cull_mode || !front_face)
    {
        return false;
    }

    id<MTLRenderCommandEncoder> encoder =
        (__bridge id<MTLRenderCommandEncoder>)encoder_handle;
    [encoder setCullMode:*cull_mode];
    [encoder setFrontFacingWinding:*front_face];
    return true;
}

} // namespace firestorm::metal
