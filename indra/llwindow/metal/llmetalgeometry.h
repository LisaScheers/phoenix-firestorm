/**
 * @file llmetalgeometry.h
 * @brief Artifact-owned vertex streams and bounded triangle draw encoding.
 *
 * $LicenseInfo:firstyear=2026&license=viewerlgpl$
 * Phoenix Firestorm Viewer Source Code
 * Copyright (C) 2026, Firestorm Viewer Project
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation;
 * version 2.1 of the License only.
 * $/LicenseInfo$
 */

#pragma once

#include "llmetalpipeline.h"
#include "llmetalresource.h"
#include "llmetalstate.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <vector>

namespace firestorm::metal
{

enum class MetalIndexType : std::uint8_t
{
    uint16,
    uint32,
};

enum class MetalDrawStatus : std::uint8_t
{
    encoded,
    invalid_state,
    invalid_argument,
};

/** One strong private-buffer binding for an artifact-declared vertex stream. */
struct MetalVertexStreamBinding
{
    std::uint8_t      bufferIndex = 0;
    MetalPrivateBuffer buffer;
    std::size_t        offset = 0;
};

/** Strong index-buffer binding; firstIndex is supplied separately in elements. */
struct MetalIndexBufferBinding
{
    MetalPrivateBuffer buffer;
    std::size_t        offset = 0;
    MetalIndexType     type = MetalIndexType::uint16;
};

/**
 * Copyable strong owner of exactly the vertex streams declared by one program.
 *
 * The implementation retains the native device, library, and private buffers,
 * and copies only the generated program/layout identity required for draws. It
 * never retains the public MetalProgramLibrary object.
 */
class MetalArtifactGeometry final
{
public:
    MetalArtifactGeometry() noexcept = default;
    MetalArtifactGeometry(const MetalArtifactGeometry&) noexcept = default;
    MetalArtifactGeometry& operator=(const MetalArtifactGeometry&) noexcept = default;
    MetalArtifactGeometry(MetalArtifactGeometry&&) noexcept = default;
    MetalArtifactGeometry& operator=(MetalArtifactGeometry&&) noexcept = default;

    bool valid() const noexcept;
    std::size_t streamCount() const noexcept;

private:
    struct Impl;

    explicit MetalArtifactGeometry(std::shared_ptr<const Impl> impl) noexcept;

    std::shared_ptr<const Impl> mImpl;

    friend std::optional<MetalArtifactGeometry>
    makeArtifactGeometry(const MetalProgramLibrary&,
                         MetalProgramId,
                         std::vector<MetalVertexStreamBinding>);
    friend MetalDrawStatus
    encodeArtifactTriangles(MetalRenderEncoderHandle,
                            const MetalArtifactPipeline&,
                            const MetalArtifactGeometry&,
                            std::size_t,
                            std::size_t) noexcept;
    friend MetalDrawStatus
    encodeArtifactIndexedTriangles(MetalRenderEncoderHandle,
                                   const MetalArtifactPipeline&,
                                   const MetalArtifactGeometry&,
                                   const MetalIndexBufferBinding&,
                                   std::size_t,
                                   std::size_t) noexcept;
};

/**
 * Matches the caller's bindings to the artifact's exact stream set.
 *
 * Missing, duplicate, or extra streams, non-private or cross-device buffers,
 * unsupported non-per-vertex layouts, misaligned offsets, and streams too
 * short for one complete vertex are rejected before ownership is published.
 */
std::optional<MetalArtifactGeometry>
makeArtifactGeometry(const MetalProgramLibrary& program_library,
                     MetalProgramId program_id,
                     std::vector<MetalVertexStreamBinding> streams);

/** Encodes one or more nonindexed triangles after complete preflight. */
MetalDrawStatus
encodeArtifactTriangles(MetalRenderEncoderHandle encoder,
                        const MetalArtifactPipeline& pipeline,
                        const MetalArtifactGeometry& geometry,
                        std::size_t first_vertex,
                        std::size_t vertex_count) noexcept;

/**
 * Encodes one or more indexed triangles after complete preflight.
 * first_index is an element index; the implementation performs checked
 * element-width multiplication before adding the binding's byte offset.
 */
MetalDrawStatus
encodeArtifactIndexedTriangles(MetalRenderEncoderHandle encoder,
                               const MetalArtifactPipeline& pipeline,
                               const MetalArtifactGeometry& geometry,
                               const MetalIndexBufferBinding& indices,
                               std::size_t first_index,
                               std::size_t index_count) noexcept;

} // namespace firestorm::metal
