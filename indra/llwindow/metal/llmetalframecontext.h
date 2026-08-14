/**
 * @file llmetalframecontext.h
 * @brief Generation-safe transient resources for three Metal frames in flight.
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

#include "llmetalframeslots.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>

namespace firestorm::metal
{

/** Unretained bridges to native Metal objects. */
using MetalDeviceHandle        = void*;
using MetalBufferHandle        = void*;
using MetalResourceHandle      = void*;
using MetalCommandBufferHandle = void*;

struct MetalFrameLease
{
    FrameToken        token;
    MetalBufferHandle buffer   = nullptr;
    std::size_t       capacity = 0;
};

struct MetalFrameAllocation
{
    std::size_t offset = 0;
    std::size_t size   = 0;
    /**
     * Aliases the lease's shared buffer at offset. It is CPU-writeable only
     * while that exact token is recording and must not be accessed after
     * submit(), cancel(), or destruction of the MetalFrameContext.
     */
    void*       bytes  = nullptr;
};

/**
 * Owns exactly three shared-buffer Metal frame contexts.
 *
 * The native handles are deliberately opaque so this interface remains usable
 * from C++. On Apple platforms, pass a bridged id<MTLDevice> to the constructor,
 * a bridged id<MTLResource> to retire(), and a bridged id<MTLCommandBuffer> to
 * submit(). Handles returned in a lease remain owned by this object.
 *
 * Normal rendering never waits: tryBegin() reports back-pressure when all three
 * contexts are in flight. Completion handlers release generation-specific
 * retired resources, reset the arena, and only then publish a context for reuse.
 * Submitted work keeps the shared implementation alive, so its completion
 * action may run after the public MetalFrameContext object is destroyed.
 */
class MetalFrameContext final
{
public:
    static constexpr std::size_t kContextCount = FrameSlots::kSlotCount;
    using CompletionAction                     = std::function<void(std::uint64_t submission_serial)>;

    MetalFrameContext(MetalDeviceHandle device, std::size_t bytes_per_context);
    ~MetalFrameContext();

    MetalFrameContext(const MetalFrameContext&)            = delete;
    MetalFrameContext& operator=(const MetalFrameContext&) = delete;
    MetalFrameContext(MetalFrameContext&&)                 = delete;
    MetalFrameContext& operator=(MetalFrameContext&&)      = delete;

    bool valid() const noexcept;

    /** Claims an available context for recording, or returns no value. */
    std::optional<MetalFrameLease> tryBegin();

    /** Checks that the exact lease still belongs to this recording context. */
    bool ownsRecordingLease(const MetalFrameLease& lease) const;

    /** Allocates a non-wrapping range from a matching recording context. */
    std::optional<MetalFrameAllocation> allocate(FrameToken token, std::size_t size, std::size_t alignment = 1);

    /** Retains a native Metal resource until this recording generation completes. */
    bool retire(FrameToken token, MetalResourceHandle resource);

    /**
     * Marks a recording generation submitted and binds its completion handler.
     *
     * The returned serial is process-wide monotonic, including across separate
     * MetalFrameContext lifetimes. A non-empty completion action runs only after
     * successful GPU completion, exact-generation cleanup, and publication of
     * the reusable context. The action runs on Metal's completion-callback
     * thread without the context mutex held. Actions may arrive out of
     * submission order; consumers must compare the supplied serial before
     * publishing newer state. Consumers should use the action, rather than slot
     * availability, as their successful GPU-visibility signal. Exceptions from
     * the action are contained after the context has been safely reclaimed. The
     * recording thread must call submit() before it commits the command buffer
     * and must not enqueue or commit that buffer concurrently with submit().
     * Rejection leaves the lease recording and cancellable.
     */
    std::optional<std::uint64_t> submit(FrameToken token, MetalCommandBufferHandle command_buffer, CompletionAction completion_action = {});

    /** Releases a matching recording generation without submitting it. */
    bool cancel(FrameToken token);

private:
    struct Impl;
    std::shared_ptr<Impl> mImpl;
};

} // namespace firestorm::metal
