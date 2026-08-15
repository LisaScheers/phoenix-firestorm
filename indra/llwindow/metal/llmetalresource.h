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

enum class MetalTextureKind : std::uint8_t
{
    texture_2d,
    cube,
    cube_array,
};

/** Portable 2D/cube edge limit across the supported Metal families. */
inline constexpr std::uint32_t kMaximumTextureDimension = 16'384;

/** Metal cube arrays contain at most 2,046 physical face slices. */
inline constexpr std::uint32_t kMaximumCubeArrayCount = 341;

/** Cube faces use Metal's physical slice order. */
enum class MetalCubeFace : std::uint8_t
{
    positive_x,
    negative_x,
    positive_y,
    negative_y,
    positive_z,
    negative_z,
};

struct MetalTextureDescriptor
{
    MetalTextureKind  kind       = MetalTextureKind::texture_2d;
    PixelFormat       format     = PixelFormat::rgba8_unorm;
    std::uint32_t     width      = 0;
    std::uint32_t     height     = 0;
    std::uint32_t     mipLevels  = 1;
    /** Logical elements: one for 2D/cube, at most 341 for cube_array. */
    std::uint32_t     arrayCount = 1;
    MetalTextureUsage usage      = MetalTextureUsage::none;
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

/** A copyable strong owner of one concrete private 2D, cube, or cube-array texture. */
class MetalPrivateTexture final
{
public:
    MetalPrivateTexture()                                               = default;
    MetalPrivateTexture(const MetalPrivateTexture&) noexcept            = default;
    MetalPrivateTexture& operator=(const MetalPrivateTexture&) noexcept = default;
    MetalPrivateTexture(MetalPrivateTexture&&) noexcept                 = default;
    MetalPrivateTexture& operator=(MetalPrivateTexture&&) noexcept      = default;

    bool              valid() const noexcept;
    MetalTextureKind  kind() const noexcept;
    PixelFormat       format() const noexcept;
    std::uint32_t     width() const noexcept;
    std::uint32_t     height() const noexcept;
    std::uint32_t     mipLevels() const noexcept;
    std::uint32_t     arrayCount() const noexcept;
    std::uint32_t     sliceCount() const noexcept;
    MetalTextureUsage usage() const noexcept;

    /** Returns cubeIndex * 6 + face for cube/cube-array resources. */
    std::optional<std::uint32_t> sliceForCubeFace(std::uint32_t cube_index,
                                                  MetalCubeFace face) const noexcept;

    /** The unretained handle remains valid while any copy of this object lives. */
    MetalTextureHandle nativeHandle() const noexcept;

private:
    struct Impl;

    explicit MetalPrivateTexture(std::shared_ptr<const Impl> impl) noexcept;

    std::shared_ptr<const Impl> mImpl;

    friend std::optional<MetalPrivateTexture>
    createPrivateTexture(MetalDeviceHandle, const MetalTextureDescriptor&);
};

/**
 * Creates an empty private 2D, cube, or cube-array texture with undefined contents.
 *
 * The usage mask must be explicit and non-empty. Cube resources must be square.
 * Edges use the portable 16,384 limit and all resources are single-sample.
 * Depth32Float is supported, except with shader_write.
 */
std::optional<MetalPrivateTexture>
createPrivateTexture(MetalDeviceHandle device,
                     const MetalTextureDescriptor& descriptor);

} // namespace firestorm::metal
