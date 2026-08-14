/**
 * @file lloraclecapture_test.cpp
 * @brief Focused tests for OpenGL oracle acquisition helpers.
 *
 * $LicenseInfo:firstyear=2026&license=viewerlgpl$
 * Copyright (C) 2026, The Phoenix Firestorm Project, Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation;
 * version 2.1 of the License only.
 * $/LicenseInfo$
 */

#include "linden_common.h"

#include "lltut.h"

#include "../lloraclecapture.h"

namespace tut
{
struct oracle_capture
{
};

using oracle_capture_group = test_group<oracle_capture>;
using oracle_capture_object = oracle_capture_group::object;
oracle_capture_group oracle_capture_tests("LLOracleCapture");

template<> template<>
void oracle_capture_object::test<1>()
{
    std::vector<U8> bytes{0, 1, 2, 3, 4, 5};
    lloracle::flipRows(bytes, 2, 3);
    ensure_equals("row flip", bytes, std::vector<U8>({4, 5, 2, 3, 0, 1}));

    lloracle::flipRows(bytes, 2, 3);
    ensure_equals("row flip is reversible", bytes, std::vector<U8>({0, 1, 2, 3, 4, 5}));
}

template<> template<>
void oracle_capture_object::test<2>()
{
    std::vector<U8> bytes{0, 1, 2};
    bool rejected = false;
    try
    {
        lloracle::flipRows(bytes, 2, 2);
    }
    catch (const std::invalid_argument&)
    {
        rejected = true;
    }
    ensure("truncated rows are rejected", rejected);
}

template<> template<>
void oracle_capture_object::test<3>()
{
    ensure("nested artifact path", lloracle::isSafeRelativePath("captures/frame-01.png"));
    ensure("single artifact name", lloracle::isSafeRelativePath("acquisition.json"));
    ensure("absolute path rejected", !lloracle::isSafeRelativePath("/tmp/frame.png"));
    ensure("parent traversal rejected", !lloracle::isSafeRelativePath("captures/../frame.png"));
    ensure("normalized spelling required", !lloracle::isSafeRelativePath("captures/./frame.png"));
    ensure("platform separators rejected", !lloracle::isSafeRelativePath("captures\\frame.png"));
    ensure("empty path rejected", !lloracle::isSafeRelativePath(""));
}

template<> template<>
void oracle_capture_object::test<4>()
{
    lloracle::CaptureSequence sequence(2, 3, 2);
    ensure("first phase", sequence.phase() == lloracle::FramePhase::WARMUP);
    ensure_equals("first serial", sequence.frameSerial(), U64(1));
    ensure_equals("nothing presented initially", sequence.presentedCount(), U64(0));
    ensure_equals("an unconfirmed presentation does not advance", sequence.frameSerial(), U64(1));
    sequence.presented();
    sequence.presented();
    ensure("measurement begins after warmup", sequence.phase() == lloracle::FramePhase::MEASUREMENT);
    ensure_equals("measurement serial", sequence.frameSerial(), U64(3));
    sequence.presented();
    sequence.presented();
    sequence.presented();
    ensure("capture begins after measurements", sequence.phase() == lloracle::FramePhase::CAPTURE);
    ensure_equals("capture serial", sequence.frameSerial(), U64(6));
    sequence.presented();
    sequence.presented();
    ensure("sequence completes exactly", sequence.complete());
    ensure("complete phase", sequence.phase() == lloracle::FramePhase::COMPLETE);
    ensure_equals("serial does not advance past completion", sequence.frameSerial(), U64(8));
    sequence.presented();
    ensure_equals("completed serial remains stable", sequence.frameSerial(), U64(8));
    ensure_equals("presented count remains exact", sequence.presentedCount(), U64(7));
}

template<> template<>
void oracle_capture_object::test<5>()
{
    ensure("self-test contract is supported",
           lloracle::isSupportedMachineContractKind("capture_self_test_v1"));
    ensure("corpus typed state is fail-closed",
           !lloracle::isSupportedMachineContractKind("typed_runtime_state_v1"));
    ensure("honest self-test window mode is supported",
           lloracle::isSupportedSelfTestWindowMode("windowed_visible_not_minimized"));
    ensure("self-test cannot claim corpus no-occlusion proof",
           !lloracle::isSupportedSelfTestWindowMode("windowed_no_occlusion"));
}

template<> template<>
void oracle_capture_object::test<6>()
{
    ensure("unprepared output has no owned staging",
           !lloracle::hasOwnedUnpublishedStaging(lloracle::OutputPublicationState::UNPREPARED));
    ensure("owned staging is unpublished cleanup state",
           lloracle::hasOwnedUnpublishedStaging(lloracle::OutputPublicationState::STAGING_OWNED));
    ensure("published output is never staging cleanup state",
           !lloracle::hasOwnedUnpublishedStaging(lloracle::OutputPublicationState::PUBLISHED));
}
}
