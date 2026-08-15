/**
 * @file llmetalframeslots.cpp
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

#include "llmetalframeslots.h"

#include <limits>

namespace firestorm::metal
{

std::optional<FrameToken> FrameSlots::tryBegin()
{
    std::lock_guard<std::mutex> lock(mMutex);

    for (std::size_t index = 0; index < mSlots.size(); ++index)
    {
        Slot& slot = mSlots[index];
        if (slot.state != State::available || slot.generation == std::numeric_limits<std::uint64_t>::max())
        {
            continue;
        }

        ++slot.generation;
        slot.state = State::recording;
        return FrameToken{ index, slot.generation };
    }

    return std::nullopt;
}

bool FrameSlots::submit(FrameToken token)
{
    return transition(token, State::recording, State::submitted);
}

bool FrameSlots::cancel(FrameToken token)
{
    return transition(token, State::recording, State::available);
}

bool FrameSlots::complete(FrameToken token)
{
    return transition(token, State::submitted, State::available);
}

bool FrameSlots::transition(FrameToken token, State from, State to)
{
    std::lock_guard<std::mutex> lock(mMutex);

    if (token.slot >= mSlots.size())
    {
        return false;
    }

    Slot& slot = mSlots[token.slot];
    if (slot.generation != token.generation || slot.state != from)
    {
        return false;
    }

    slot.state = to;
    return true;
}

} // namespace firestorm::metal
