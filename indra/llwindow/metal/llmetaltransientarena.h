/**
 * @file llmetaltransientarena.h
 * @brief CPU-side linear allocator for transient Metal frame data.
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
#include <optional>

namespace firestorm::metal
{

struct TransientRange
{
    std::size_t offset = 0;
    std::size_t size   = 0;
};

constexpr bool operator==(TransientRange lhs, TransientRange rhs) noexcept
{
    return lhs.offset == rhs.offset && lhs.size == rhs.size;
}

constexpr bool operator!=(TransientRange lhs, TransientRange rhs) noexcept
{
    return !(lhs == rhs);
}

/**
 * A non-wrapping, thread-confined linear allocator.
 *
 * Alignment may be any positive value, not only a power of two. Zero-byte
 * allocations and zero alignment are rejected. A failed allocation leaves the
 * cursor and high-water mark unchanged. reset() rewinds the cursor while
 * preserving the lifetime high-water mark.
 */
class TransientArena final
{
public:
    explicit constexpr TransientArena(std::size_t capacity) noexcept : mCapacity(capacity) {}

    std::optional<TransientRange> allocate(std::size_t size, std::size_t alignment = 1) noexcept;

    constexpr void reset() noexcept { mUsed = 0; }

    constexpr std::size_t used() const noexcept { return mUsed; }

    constexpr std::size_t highWater() const noexcept { return mHighWater; }

    constexpr std::size_t capacity() const noexcept { return mCapacity; }

private:
    std::size_t mCapacity  = 0;
    std::size_t mUsed      = 0;
    std::size_t mHighWater = 0;
};

} // namespace firestorm::metal
