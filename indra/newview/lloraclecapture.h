/**
 * @file lloraclecapture.h
 * @brief Developer-only OpenGL oracle acquisition controller.
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

#ifndef LL_LLORACLECAPTURE_H
#define LL_LLORACLECAPTURE_H

#include "stdtypes.h"

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace lloracle
{
enum class FramePhase
{
    WARMUP,
    MEASUREMENT,
    CAPTURE,
    COMPLETE
};

enum class OutputPublicationState
{
    UNPREPARED,
    STAGING_OWNED,
    PUBLISHED
};

class CaptureSequence
{
public:
    CaptureSequence(U32 warmup_frames, U32 measurement_frames, U32 capture_frames);

    FramePhase phase() const;
    U64 frameSerial() const;
    U64 presentedCount() const;
    void presented();
    bool complete() const;

private:
    U64 mPresented = 0;
    U64 mWarmupEnd;
    U64 mMeasurementEnd;
    U64 mCaptureEnd;
};

void flipRows(std::vector<U8>& bytes, std::size_t row_bytes, std::size_t height);
bool isSafeRelativePath(const std::string& path);
bool isSupportedMachineContractKind(std::string_view kind);
bool isSupportedSelfTestWindowMode(std::string_view mode);
bool hasOwnedUnpublishedStaging(OutputPublicationState state);
}

class LLOracleCapture
{
public:
    static bool configure(
        const std::string& request_path,
        const std::string& output_directory,
        std::string& error);
    static void shutdown();

    static bool enabled();
    static bool displayActive();

    // beginDisplay() is called only for a real, non-snapshot display attempt.
    static bool beginDisplay();

    // beforePresent() runs immediately before the platform swap. It returns
    // false when acquisition failed and the swap must not be counted.
    static bool beforePresent();
    // Report exactly one outcome from the checked platform swap.
    static void didPresent();
    static void presentationFailed();

    // Discards a display attempt that did not reach a platform swap.
    static void cancelDisplay();
};

#endif // LL_LLORACLECAPTURE_H
