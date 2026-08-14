/**
 * @file llmetalbootstrap.h
 * @brief C++ boundary for the native Metal presentation bootstrap.
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

#include <chrono>
#include <cstdint>
#include <memory>
#include <string>

namespace firestorm::metal
{

enum class FrameSubmission
{
    submitted,
    drawable_unavailable,
    renderer_busy,
    failed,
};

const char* toString(FrameSubmission submission) noexcept;

/**
 * Owns an NSView backed by CAMetalLayer without exposing Objective-C types to
 * ordinary C++ callers. All view and drawing methods must be called on the
 * AppKit main thread.
 */
class LLMetalBootstrap final
{
public:
    static std::unique_ptr<LLMetalBootstrap> create(
        const std::string& metallib_path,
        std::string& error);

    ~LLMetalBootstrap();

    LLMetalBootstrap(const LLMetalBootstrap&) = delete;
    LLMetalBootstrap& operator=(const LLMetalBootstrap&) = delete;
    LLMetalBootstrap(LLMetalBootstrap&&) = delete;
    LLMetalBootstrap& operator=(LLMetalBootstrap&&) = delete;

    /** Returns an unretained NSView pointer. */
    void* nativeView() const noexcept;

    /** Requests an event-driven AppKit redraw. */
    void requestFrame() noexcept;

    /** Submits a frame immediately, bypassing AppKit invalidation. */
    FrameSubmission drawFrame(std::string* error = nullptr) noexcept;

    /** Waits for every frame submitted before this call to finish. */
    bool waitForIdle(
        std::chrono::milliseconds timeout,
        std::string* error = nullptr) noexcept;

    /** Waits for every frame submitted before this call to be presented. */
    bool waitForPresent(
        std::chrono::milliseconds timeout,
        std::string* error = nullptr) noexcept;

    std::uint64_t submittedFrameCount() const noexcept;
    std::uint64_t completedFrameCount() const noexcept;
    std::uint64_t presentedFrameCount() const noexcept;
    std::string capabilityReport() const;

private:
    struct Impl;

    explicit LLMetalBootstrap(std::unique_ptr<Impl> implementation);

    std::unique_ptr<Impl> mImpl;
};

} // namespace firestorm::metal
