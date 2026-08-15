/**
 * @file llmetaltransfer.h
 * @brief Bounded recording-scoped Metal uploads and asynchronous readbacks.
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

#include "llmetalresource.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace firestorm::metal
{

struct MetalByteView
{
    const std::byte* data = nullptr;
    std::size_t      size = 0;
};

/** One complete texture subresource. Rows remain in caller/Metal order. */
struct MetalTextureSubresourceUpload
{
    std::uint32_t mipLevel = 0;
    std::uint32_t slice    = 0;
    MetalByteView bytes;
    std::size_t   bytesPerRow = 0;
};

struct MetalTextureRegion
{
    std::uint32_t x        = 0;
    std::uint32_t y        = 0;
    std::uint32_t width    = 0;
    std::uint32_t height   = 0;
    std::uint32_t mipLevel = 0;
    std::uint32_t slice    = 0;
};

struct MetalBufferReadback
{
    std::size_t            sourceOffset = 0;
    std::vector<std::byte> bytes;
};

struct MetalTextureReadback
{
    PixelFormat            format = PixelFormat::rgba8_unorm;
    MetalTextureRegion     region;
    std::size_t            bytesPerRow   = 0;
    std::size_t            bytesPerImage = 0;
    std::vector<std::byte> bytes;
};

enum class MetalTransferStatus : std::uint8_t
{
    encoded,
    invalid_state,
    invalid_argument,
    staging_full,
    readback_budget_exceeded,
    resource_allocation_failed,
    encoder_unavailable,
    retirement_failed,
};

/**
 * Owns one recording frame lease and borrows one caller-owned command buffer.
 *
 * The batch lazily opens one blit encoder and never creates, commits, or waits
 * for a command buffer. Upload bytes use only the lease's bounded shared arena.
 * Readbacks use dedicated shared buffers bounded by readback_budget_bytes.
 * finish() relinquishes the lease and returns the sole success action to pass
 * to MetalFrameContext::submit. Until then, cancel() or destruction cancels the
 * lease. MetalFrameContext must outlive an active batch. After cancellation the
 * caller must abandon and never commit the borrowed command buffer. Completion
 * callbacks run in registration order on Metal's callback thread, only after a
 * successful command, and receive the submission serial for stale-result checks.
 */
class MetalTransferBatch final
{
public:
    using PublishBuffer          = std::function<void(std::uint64_t submission_serial, MetalPrivateBuffer buffer)>;
    using PublishTexture         = std::function<void(std::uint64_t submission_serial, MetalPrivateTexture texture)>;
    using PublishBufferReadback  = std::function<void(std::uint64_t submission_serial, MetalBufferReadback readback)>;
    using PublishTextureReadback = std::function<void(std::uint64_t submission_serial, MetalTextureReadback readback)>;

    MetalTransferBatch(MetalDeviceHandle        device,
                       MetalFrameContext&       frames,
                       MetalFrameLease          lease,
                       MetalCommandBufferHandle command_buffer,
                       std::size_t              readback_budget_bytes);
    ~MetalTransferBatch();

    MetalTransferBatch(const MetalTransferBatch&)            = delete;
    MetalTransferBatch& operator=(const MetalTransferBatch&) = delete;
    MetalTransferBatch(MetalTransferBatch&&)                 = delete;
    MetalTransferBatch& operator=(MetalTransferBatch&&)      = delete;

    bool valid() const noexcept;

    MetalTransferStatus uploadPrivateBuffer(MetalByteView source, std::string label, PublishBuffer publish);

    /**
     * Creates an immutable texture from every physical (mip, slice) exactly
     * once. All caller-controlled descriptor, identity, and byte bounds are
     * validated before native texture or arena allocation. The upload uses one
     * aggregate 256-byte-aligned staging range.
     */
    MetalTransferStatus uploadPrivateTexture(
        const MetalTextureDescriptor& descriptor,
        const std::vector<MetalTextureSubresourceUpload>& subresources,
        PublishTexture publish);

    MetalTransferStatus readbackBuffer(const MetalPrivateBuffer& source,
                                       std::size_t               offset,
                                       std::size_t               size,
                                       PublishBufferReadback     publish);

    /**
     * Reads one in-bounds physical slice/mip region. Returned row zero is
     * Metal y=region.y; no flip occurs. Returned rows use bytesPerRow, which
     * may exceed the tight row size.
     */
    MetalTransferStatus readbackTexture(const MetalPrivateTexture& source,
                                        MetalTextureRegion region,
                                        PublishTextureReadback publish);

    /**
     * Ends encoding and transfers all success-only publications exactly once.
     * An empty valid batch returns a no-op action. The caller then owns the
     * recording lease and must submit or cancel it; this method never does so.
     */
    std::optional<MetalFrameContext::CompletionAction> finish();

    /**
     * Ends encoding, drops every pending publication, and cancels the lease.
     * The caller must then abandon and never commit the command buffer.
     */
    void cancel() noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> mImpl;
};

} // namespace firestorm::metal
