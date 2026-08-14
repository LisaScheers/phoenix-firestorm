/**
 * @file frame-contracts-test.cpp
 * @brief Focused tests for the CPU-side Metal frame contracts.
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
#include "llmetaltransientarena.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <optional>

namespace
{

int gFailures = 0;

void expect(bool condition, const char* expression, int line)
{
    if (!condition)
    {
        std::cerr << "FAIL line " << line << ": " << expression << '\n';
        ++gFailures;
    }
}

#define EXPECT(expression) expect(static_cast<bool>(expression), #expression, __LINE__)

using firestorm::metal::FrameSlots;
using firestorm::metal::FrameToken;
using firestorm::metal::TransientArena;
using firestorm::metal::TransientRange;

void testTransientAlignment()
{
    TransientArena arena(64);

    EXPECT(arena.capacity() == 64);
    EXPECT(arena.used() == 0);
    EXPECT(arena.highWater() == 0);

    const auto first = arena.allocate(3);
    EXPECT(first == std::optional<TransientRange>({ 0, 3 }));
    EXPECT(arena.used() == 3);

    const auto power_of_two = arena.allocate(4, 8);
    EXPECT(power_of_two == std::optional<TransientRange>({ 8, 4 }));
    EXPECT(arena.used() == 12);

    const auto general_alignment = arena.allocate(2, 7);
    EXPECT(general_alignment == std::optional<TransientRange>({ 14, 2 }));
    EXPECT(arena.used() == 16);
    EXPECT(arena.highWater() == 16);
}

void testTransientFailureAndReset()
{
    TransientArena arena(32);

    EXPECT(arena.allocate(8, 8).has_value());
    EXPECT(arena.used() == 8);
    EXPECT(arena.highWater() == 8);

    EXPECT(!arena.allocate(0, 1).has_value());
    EXPECT(!arena.allocate(1, 0).has_value());
    EXPECT(!arena.allocate(std::numeric_limits<std::size_t>::max(), 1).has_value());
    EXPECT(!arena.allocate(1, std::numeric_limits<std::size_t>::max()).has_value());
    EXPECT(arena.used() == 8);
    EXPECT(arena.highWater() == 8);

    const auto remainder = arena.allocate(24);
    EXPECT(remainder == std::optional<TransientRange>({ 8, 24 }));
    EXPECT(arena.used() == 32);
    EXPECT(arena.highWater() == 32);
    EXPECT(!arena.allocate(1).has_value());
    EXPECT(arena.used() == 32);
    EXPECT(arena.highWater() == 32);

    arena.reset();
    EXPECT(arena.used() == 0);
    EXPECT(arena.highWater() == 32);
    EXPECT(arena.allocate(4, 4) == std::optional<TransientRange>({ 0, 4 }));
    EXPECT(arena.used() == 4);
    EXPECT(arena.highWater() == 32);
}

void testThreeSlotsAndOutOfOrderCompletion()
{
    FrameSlots slots;

    const auto first  = slots.tryBegin();
    const auto second = slots.tryBegin();
    const auto third  = slots.tryBegin();
    EXPECT(first.has_value());
    EXPECT(second.has_value());
    EXPECT(third.has_value());
    EXPECT(first->slot == 0);
    EXPECT(second->slot == 1);
    EXPECT(third->slot == 2);
    EXPECT(!slots.tryBegin().has_value());

    EXPECT(slots.submit(*first));
    EXPECT(slots.submit(*second));
    EXPECT(slots.submit(*third));

    EXPECT(slots.complete(*third));
    const auto third_reused = slots.tryBegin();
    EXPECT(third_reused.has_value());
    EXPECT(third_reused->slot == third->slot);
    EXPECT(third_reused->generation > third->generation);
    EXPECT(!slots.complete(*third));

    EXPECT(slots.complete(*first));
    EXPECT(slots.complete(*second));
    EXPECT(slots.cancel(*third_reused));

    EXPECT(slots.tryBegin().has_value());
    EXPECT(slots.tryBegin().has_value());
    EXPECT(slots.tryBegin().has_value());
    EXPECT(!slots.tryBegin().has_value());
}

void testTokenStateAndGenerationChecks()
{
    FrameSlots slots;

    const FrameToken invalid_slot{ FrameSlots::kSlotCount, 1 };
    EXPECT(!slots.submit(invalid_slot));
    EXPECT(!slots.cancel(invalid_slot));
    EXPECT(!slots.complete(invalid_slot));

    const auto first = slots.tryBegin();
    EXPECT(first.has_value());
    EXPECT(!slots.complete(*first));
    EXPECT(slots.cancel(*first));
    EXPECT(!slots.cancel(*first));
    EXPECT(!slots.submit(*first));

    const auto reused = slots.tryBegin();
    EXPECT(reused.has_value());
    EXPECT(reused->slot == first->slot);
    EXPECT(reused->generation > first->generation);
    EXPECT(!slots.submit(*first));
    EXPECT(!slots.cancel(*first));
    EXPECT(!slots.complete(*first));

    EXPECT(slots.submit(*reused));
    EXPECT(!slots.submit(*reused));
    EXPECT(!slots.cancel(*reused));
    EXPECT(slots.complete(*reused));
    EXPECT(!slots.complete(*reused));
}

} // namespace

int main()
{
    testTransientAlignment();
    testTransientFailureAndReset();
    testThreeSlotsAndOutOfOrderCompletion();
    testTokenStateAndGenerationChecks();

    if (gFailures != 0)
    {
        std::cerr << gFailures << " CPU frame contract test(s) failed\n";
        return EXIT_FAILURE;
    }

    std::cout << "PASS Metal CPU frame contracts\n";
    return EXIT_SUCCESS;
}
