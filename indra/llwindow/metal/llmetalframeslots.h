/**
 * @file llmetalframeslots.h
 * @brief Three-slot CPU frame lifecycle for the Metal renderer.
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

#include <array>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>

namespace firestorm::metal
{

struct FrameToken
{
    std::size_t   slot       = 0;
    std::uint64_t generation = 0;
};

constexpr bool operator==(FrameToken lhs, FrameToken rhs) noexcept
{
    return lhs.slot == rhs.slot && lhs.generation == rhs.generation;
}

constexpr bool operator!=(FrameToken lhs, FrameToken rhs) noexcept
{
    return !(lhs == rhs);
}

/**
 * Owns exactly three generation-tagged frame slots.
 *
 * The expected usage is one recording/submission thread plus completion
 * callbacks from any thread. All methods are internally synchronized, and
 * completion order is unrestricted. A token is accepted only while its slot,
 * generation, and lifecycle state match the requested transition.
 */
class FrameSlots final
{
public:
    static constexpr std::size_t kSlotCount = 3;

    FrameSlots() = default;

    FrameSlots(const FrameSlots&)            = delete;
    FrameSlots& operator=(const FrameSlots&) = delete;
    FrameSlots(FrameSlots&&)                 = delete;
    FrameSlots& operator=(FrameSlots&&)      = delete;

    /** Claims an available slot and moves it to recording. */
    std::optional<FrameToken> tryBegin();

    /** Moves a matching recording slot to submitted. */
    bool submit(FrameToken token);

    /** Returns a matching recording slot to available without submitting it. */
    bool cancel(FrameToken token);

    /** Returns a matching submitted slot to available. */
    bool complete(FrameToken token);

private:
    enum class State
    {
        available,
        recording,
        submitted,
    };

    struct Slot
    {
        State         state      = State::available;
        std::uint64_t generation = 0;
    };

    bool transition(FrameToken token, State from, State to);

    std::array<Slot, kSlotCount> mSlots{};
    std::mutex                   mMutex;
};

} // namespace firestorm::metal
