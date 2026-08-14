/**
 * @file llmetalresource.h
 * @brief Strong-owning C++ handles for concrete private Metal resources.
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

namespace firestorm::metal
{

/** Unretained bridge to an id<MTLTexture>. */
using MetalTextureHandle = void*;

enum class MetalTextureUsage : std::uint8_t
{
    none          = 0,
    shader_read   = 1U << 0U,
    shader_write  = 1U << 1U,
    render_target = 1U << 2U,
};

constexpr MetalTextureUsage operator|(MetalTextureUsage lhs, MetalTextureUsage rhs) noexcept
{
    return static_cast<MetalTextureUsage>(static_cast<std::uint8_t>(lhs) | static_cast<std::uint8_t>(rhs));
}

constexpr MetalTextureUsage operator&(MetalTextureUsage lhs, MetalTextureUsage rhs) noexcept
{
    return static_cast<MetalTextureUsage>(static_cast<std::uint8_t>(lhs) & static_cast<std::uint8_t>(rhs));
}

constexpr bool hasUsage(MetalTextureUsage value, MetalTextureUsage usage) noexcept
{
    return (value & usage) == usage;
}

struct MetalTexture2DDescriptor
{
    PixelFormat       format    = PixelFormat::rgba8_unorm;
    std::uint32_t     width     = 0;
    std::uint32_t     height    = 0;
    std::uint32_t     mipLevels = 1;
    MetalTextureUsage usage     = MetalTextureUsage::none;
    std::string       label;
};

class MetalTransferBatch;

/** A copyable strong owner of one concrete MTLStorageModePrivate buffer. */
class MetalPrivateBuffer final
{
public:
    MetalPrivateBuffer()                                              = default;
    MetalPrivateBuffer(const MetalPrivateBuffer&) noexcept            = default;
    MetalPrivateBuffer& operator=(const MetalPrivateBuffer&) noexcept = default;
    MetalPrivateBuffer(MetalPrivateBuffer&&) noexcept                 = default;
    MetalPrivateBuffer& operator=(MetalPrivateBuffer&&) noexcept      = default;

    bool        valid() const noexcept;
    std::size_t size() const noexcept;

    /** The unretained handle remains valid while any copy of this object lives. */
    MetalBufferHandle nativeHandle() const noexcept;

private:
    struct Impl;

    explicit MetalPrivateBuffer(std::shared_ptr<const Impl> impl) noexcept;
    static std::optional<MetalPrivateBuffer> create(MetalDeviceHandle device, std::size_t size, const std::string& label);

    std::shared_ptr<const Impl> mImpl;

    friend class MetalTransferBatch;
};

/** A copyable strong owner of one concrete private, single-slice 2D texture. */
class MetalPrivateTexture2D final
{
public:
    MetalPrivateTexture2D()                                                 = default;
    MetalPrivateTexture2D(const MetalPrivateTexture2D&) noexcept            = default;
    MetalPrivateTexture2D& operator=(const MetalPrivateTexture2D&) noexcept = default;
    MetalPrivateTexture2D(MetalPrivateTexture2D&&) noexcept                 = default;
    MetalPrivateTexture2D& operator=(MetalPrivateTexture2D&&) noexcept      = default;

    bool              valid() const noexcept;
    PixelFormat       format() const noexcept;
    std::uint32_t     width() const noexcept;
    std::uint32_t     height() const noexcept;
    std::uint32_t     mipLevels() const noexcept;
    MetalTextureUsage usage() const noexcept;

    /** The unretained handle remains valid while any copy of this object lives. */
    MetalTextureHandle nativeHandle() const noexcept;

private:
    struct Impl;

    explicit MetalPrivateTexture2D(std::shared_ptr<const Impl> impl) noexcept;

    std::shared_ptr<const Impl> mImpl;

    friend std::optional<MetalPrivateTexture2D> createPrivateTexture2D(MetalDeviceHandle               device,
                                                                       const MetalTexture2DDescriptor& descriptor);
};

/**
 * Creates an empty private 2D texture with undefined contents.
 *
 * The usage mask must be explicit and non-empty. The texture has one array
 * slice and one sample. Depth32Float is supported, except with shader_write.
 */
std::optional<MetalPrivateTexture2D> createPrivateTexture2D(MetalDeviceHandle device, const MetalTexture2DDescriptor& descriptor);

} // namespace firestorm::metal
