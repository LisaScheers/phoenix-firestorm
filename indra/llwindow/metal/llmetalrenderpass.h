/**
 * @file llmetalrenderpass.h
 * @brief Strong render targets and typed Metal attachment encoder scopes.
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
#include "llmetalstate.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace firestorm::metal
{

enum class AttachmentLoadAction : std::uint8_t
{
    dont_care,
    load,
    clear,
};

enum class AttachmentStoreAction : std::uint8_t
{
    dont_care,
    store,
};

struct MetalClearColor
{
    double red   = 0.0;
    double green = 0.0;
    double blue  = 0.0;
    double alpha = 0.0;
};

struct MetalColorAttachmentDesc
{
    AttachmentLoadAction  load  = AttachmentLoadAction::dont_care;
    AttachmentStoreAction store = AttachmentStoreAction::dont_care;
    MetalClearColor        clear;
};

struct MetalDepthAttachmentDesc
{
    AttachmentLoadAction  load  = AttachmentLoadAction::dont_care;
    AttachmentStoreAction store = AttachmentStoreAction::dont_care;
    double                clear = 1.0;
};

/**
 * Strongly owns zero-to-four ordered private mip-zero, single-sample color
 * attachments and an optional matching Depth32Float attachment. A valid target
 * always owns at least one attachment.
 */
class MetalRenderTarget final
{
public:
    MetalRenderTarget()                                            = default;
    MetalRenderTarget(const MetalRenderTarget&) noexcept            = default;
    MetalRenderTarget& operator=(const MetalRenderTarget&) noexcept = default;
    MetalRenderTarget(MetalRenderTarget&&) noexcept                 = default;
    MetalRenderTarget& operator=(MetalRenderTarget&&) noexcept      = default;

    bool valid() const noexcept;

    std::uint32_t width() const noexcept;
    std::uint32_t height() const noexcept;
    std::uint32_t sampleCount() const noexcept;
    std::size_t colorCount() const noexcept;
    std::optional<PixelFormat> colorFormat(std::size_t index) const noexcept;
    std::optional<PixelFormat> depthFormat() const noexcept;

    /** Returned values are additional strong owners of the attachments. */
    std::optional<MetalPrivateTexture> colorTexture(std::size_t index) const noexcept;
    std::optional<MetalPrivateTexture> depthTexture() const noexcept;

private:
    struct Impl;

    explicit MetalRenderTarget(std::shared_ptr<const Impl> impl) noexcept;

    std::shared_ptr<const Impl> mImpl;

    friend std::optional<MetalRenderTarget>
    makeRenderTarget(std::vector<MetalPrivateTexture>,
                     std::optional<MetalPrivateTexture>);
};

/**
 * Validates and groups existing private textures without allocating or
 * changing any texture. Every attachment must be a unique render-target
 * capable, mip-zero, single-sample 2D resource on one device and with one
 * extent. Zero colors is valid only with depth; at most four colors are valid.
 */
std::optional<MetalRenderTarget>
makeRenderTarget(std::vector<MetalPrivateTexture> colors,
                 std::optional<MetalPrivateTexture> depth = std::nullopt);

struct MetalRenderPassDesc
{
    std::vector<MetalColorAttachmentDesc> colors;
    std::optional<MetalDepthAttachmentDesc> depth;
    std::string label;
};

/**
 * Owns one active render encoder and borrows its command buffer.
 *
 * The encoder handle is valid only while active(). end() closes the native
 * encoder exactly once. Destruction also closes an active encoder, but never
 * creates, commits, waits for, submits, or cancels a command buffer or frame.
 * Move assignment first closes an active destination encoder, then transfers
 * the source scope; this is the intentional RAII replacement contract.
 */
class MetalRenderPass final
{
public:
    ~MetalRenderPass();

    MetalRenderPass(const MetalRenderPass&)            = delete;
    MetalRenderPass& operator=(const MetalRenderPass&) = delete;
    MetalRenderPass(MetalRenderPass&&) noexcept;
    MetalRenderPass& operator=(MetalRenderPass&&) noexcept;

    bool active() const noexcept;
    MetalRenderEncoderHandle encoder() const noexcept;
    bool end() noexcept;

private:
    struct Impl;

    explicit MetalRenderPass(std::unique_ptr<Impl> impl) noexcept;

    std::unique_ptr<Impl> mImpl;

    friend std::optional<MetalRenderPass>
    beginRenderPass(MetalCommandBufferHandle,
                    const MetalRenderTarget&,
                    const MetalRenderPassDesc&);
};

/**
 * Opens one render encoder after validating every caller-controlled field.
 * The depth descriptor must be present exactly when the target has depth.
 * The caller must not already have an active encoder on command_buffer and
 * must externally serialize this call, encoder use/end, enqueue, and commit
 * for that command buffer. Both not-enqueued and explicitly enqueued buffers
 * are accepted because encoding remains open until commit; committed buffers
 * are rejected. The status check and encoder creation rely on that external
 * serialization and are not made atomic with an internal lock.
 */
std::optional<MetalRenderPass>
beginRenderPass(MetalCommandBufferHandle command_buffer,
                const MetalRenderTarget& target,
                const MetalRenderPassDesc& descriptor);

} // namespace firestorm::metal
