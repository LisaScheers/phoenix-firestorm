/**
 * @file llmetaltransientarena.cpp
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

#include "llmetaltransientarena.h"

namespace firestorm::metal
{

std::optional<TransientRange> TransientArena::allocate(std::size_t size, std::size_t alignment) noexcept
{
    if (size == 0 || alignment == 0)
    {
        return std::nullopt;
    }

    const std::size_t remainder = mUsed % alignment;
    const std::size_t padding   = remainder == 0 ? 0 : alignment - remainder;

    // Subtraction-based bounds checks avoid overflowing the aligned offset or
    // the allocation end. mUsed never exceeds mCapacity.
    if (padding > mCapacity - mUsed)
    {
        return std::nullopt;
    }

    const std::size_t offset = mUsed + padding;
    if (size > mCapacity - offset)
    {
        return std::nullopt;
    }

    mUsed = offset + size;
    if (mUsed > mHighWater)
    {
        mHighWater = mUsed;
    }

    return TransientRange{ offset, size };
}

} // namespace firestorm::metal
