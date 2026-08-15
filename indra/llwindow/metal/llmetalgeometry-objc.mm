/**
 * @file llmetalgeometry-objc.mm
 * @brief Native validation and encoding for artifact-owned triangle geometry.
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

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "llmetalgeometry.h"

#include <algorithm>
#include <limits>
#include <string>
#include <utility>
#include <vector>

namespace firestorm::metal
{
namespace
{

bool conformsToMetalProtocol(void* handle, Protocol* protocol) noexcept
{
    id object = (__bridge id)handle;
    return object != nil && [object conformsToProtocol:protocol];
}

std::size_t vertexFormatAlignment(MetalVertexFormat format) noexcept
{
    switch (format)
    {
        case MetalVertexFormat::uint8x4_normalized:
            return 1;
        case MetalVertexFormat::uint16x4:
            return 2;
        case MetalVertexFormat::float32:
        case MetalVertexFormat::float32x2:
        case MetalVertexFormat::float32x3:
        case MetalVertexFormat::float32x4:
        case MetalVertexFormat::int32:
        case MetalVertexFormat::int32x2:
        case MetalVertexFormat::int32x3:
        case MetalVertexFormat::int32x4:
        case MetalVertexFormat::uint32:
        case MetalVertexFormat::uint32x2:
        case MetalVertexFormat::uint32x3:
        case MetalVertexFormat::uint32x4:
            return 4;
    }
    return 0;
}

bool checkedAdd(std::size_t left,
                std::size_t right,
                std::size_t& result) noexcept
{
    if (left > std::numeric_limits<std::size_t>::max() - right)
    {
        return false;
    }
    result = left + right;
    return true;
}

bool checkedMultiply(std::size_t left,
                     std::size_t right,
                     std::size_t& result) noexcept
{
    if (left != 0 && right > std::numeric_limits<std::size_t>::max() / left)
    {
        return false;
    }
    result = left * right;
    return true;
}

struct StreamRequirement
{
    std::uint8_t bufferIndex = 0;
    std::size_t  stride = 0;
    std::size_t  alignment = 0;
    std::size_t  extent = 0;
};

struct OwnedVertexStream
{
    std::uint8_t       bufferIndex = 0;
    std::size_t        stride = 0;
    std::size_t        extent = 0;
    MetalPrivateBuffer buffer;
    std::size_t        offset = 0;
};

std::optional<StreamRequirement>
streamRequirement(const MetalProgramDescriptor& program,
                  const MetalVertexBufferLayoutDescriptor& layout) noexcept
{
    if (layout.stepFunction != MetalVertexStepFunction::per_vertex ||
        layout.stride == 0)
    {
        return std::nullopt;
    }

    StreamRequirement requirement;
    requirement.bufferIndex = layout.bufferIndex;
    requirement.stride = layout.stride;
    for (const MetalVertexAttributeDescriptor& attribute : program.vertexAttributes)
    {
        if (attribute.bufferIndex != layout.bufferIndex)
        {
            continue;
        }
        const std::size_t alignment = vertexFormatAlignment(attribute.format);
        const std::size_t size = metalVertexFormatSize(attribute.format);
        std::size_t extent = 0;
        if (alignment == 0 || size == 0 ||
            !checkedAdd(attribute.offset, size, extent) ||
            extent > layout.stride)
        {
            return std::nullopt;
        }
        requirement.alignment = std::max(requirement.alignment, alignment);
        requirement.extent = std::max(requirement.extent, extent);
    }
    if (requirement.alignment == 0 || requirement.extent == 0)
    {
        return std::nullopt;
    }
    return requirement;
}

bool validPrivateBuffer(const MetalPrivateBuffer& buffer,
                        id<MTLDevice> expected_device,
                        id<MTLBuffer> __strong& native_buffer) noexcept
{
    if (!buffer.valid() ||
        !conformsToMetalProtocol(buffer.nativeHandle(), @protocol(MTLBuffer)))
    {
        return false;
    }
    native_buffer = (__bridge id<MTLBuffer>)buffer.nativeHandle();
    return native_buffer != nil && native_buffer.device == expected_device &&
           native_buffer.storageMode == MTLStorageModePrivate &&
           native_buffer.length == buffer.size();
}

std::optional<std::pair<std::size_t, MTLIndexType>>
nativeIndexType(MetalIndexType type) noexcept
{
    switch (type)
    {
        case MetalIndexType::uint16:
            return std::pair<std::size_t, MTLIndexType>{ 2, MTLIndexTypeUInt16 };
        case MetalIndexType::uint32:
            return std::pair<std::size_t, MTLIndexType>{ 4, MTLIndexTypeUInt32 };
    }
    return std::nullopt;
}

bool validVertexRange(const std::vector<OwnedVertexStream>& streams,
                      std::size_t first_vertex,
                      std::size_t vertex_count) noexcept
{
    if (vertex_count == 0 || vertex_count % 3 != 0)
    {
        return false;
    }

    std::size_t last_vertex = 0;
    if (!checkedAdd(first_vertex, vertex_count - 1, last_vertex))
    {
        return false;
    }
    for (const OwnedVertexStream& stream : streams)
    {
        if (stream.stride == 0 || stream.extent == 0 ||
            !stream.buffer.valid())
        {
            return false;
        }
        std::size_t vertex_offset = 0;
        std::size_t byte_start = 0;
        std::size_t byte_end = 0;
        if (!checkedMultiply(last_vertex, stream.stride, vertex_offset) ||
            !checkedAdd(stream.offset, vertex_offset, byte_start) ||
            !checkedAdd(byte_start, stream.extent, byte_end) ||
            byte_end > stream.buffer.size())
        {
            return false;
        }
    }
    return true;
}

struct EncoderPreflight
{
    id<MTLRenderCommandEncoder> encoder = nil;
    id<MTLRenderPipelineState> pipeline = nil;
};

} // namespace

struct MetalArtifactGeometry::Impl
{
    Impl(id<MTLDevice> native_device,
         id<MTLLibrary> native_library,
         MetalProgramId native_program_id,
         std::string native_reflection_sha256,
         std::vector<OwnedVertexStream> native_streams) :
        device(native_device),
        library(native_library),
        programId(native_program_id),
        reflectionSha256(std::move(native_reflection_sha256)),
        streams(std::move(native_streams))
    {
    }

    __strong id<MTLDevice> device;
    __strong id<MTLLibrary> library;
    MetalProgramId programId;
    std::string reflectionSha256;
    std::vector<OwnedVertexStream> streams;
};

namespace
{

std::optional<EncoderPreflight>
preflightEncoder(MetalRenderEncoderHandle encoder_handle,
                 const MetalArtifactPipeline& pipeline,
                 id<MTLDevice> device,
                 id<MTLLibrary> library,
                 MetalProgramId program_id,
                 std::string_view reflection_sha256,
                 const std::vector<OwnedVertexStream>& streams) noexcept
{
    if (!pipeline.valid() ||
        !conformsToMetalProtocol(encoder_handle,
                                @protocol(MTLRenderCommandEncoder)) ||
        !pipeline.matches((__bridge void*)device,
                          (__bridge void*)library,
                          program_id,
                          reflection_sha256) ||
        !conformsToMetalProtocol(pipeline.nativeHandle(),
                                @protocol(MTLRenderPipelineState)))
    {
        return std::nullopt;
    }

    id<MTLRenderCommandEncoder> encoder =
        (__bridge id<MTLRenderCommandEncoder>)encoder_handle;
    id<MTLRenderPipelineState> native_pipeline =
        (__bridge id<MTLRenderPipelineState>)pipeline.nativeHandle();
    if (encoder.device != device || native_pipeline.device != device)
    {
        return std::nullopt;
    }
    for (const OwnedVertexStream& stream : streams)
    {
        id<MTLBuffer> native_buffer = nil;
        if (!validPrivateBuffer(stream.buffer,
                                device,
                                native_buffer))
        {
            return std::nullopt;
        }
    }
    return EncoderPreflight{ encoder, native_pipeline };
}

void bindPipelineAndStreams(const EncoderPreflight& preflight,
                            const std::vector<OwnedVertexStream>& streams) noexcept
{
    [preflight.encoder setRenderPipelineState:preflight.pipeline];
    for (const OwnedVertexStream& stream : streams)
    {
        [preflight.encoder
            setVertexBuffer:(__bridge id<MTLBuffer>)stream.buffer.nativeHandle()
                     offset:stream.offset
                    atIndex:stream.bufferIndex];
    }
}

} // namespace

MetalArtifactGeometry::MetalArtifactGeometry(
    std::shared_ptr<const Impl> impl) noexcept :
    mImpl(std::move(impl))
{
}

bool MetalArtifactGeometry::valid() const noexcept
{
    return mImpl != nullptr && mImpl->device != nil && mImpl->library != nil &&
           !mImpl->reflectionSha256.empty() && !mImpl->streams.empty();
}

std::size_t MetalArtifactGeometry::streamCount() const noexcept
{
    return valid() ? mImpl->streams.size() : 0;
}

std::optional<MetalArtifactGeometry>
makeArtifactGeometry(const MetalProgramLibrary& program_library,
                     MetalProgramId program_id,
                     std::vector<MetalVertexStreamBinding> streams)
{
    const MetalProgramDescriptor* program = program_library.program(program_id);
    const MetalProgramLibraryHandle library_handle =
        program_library.nativeLibrary();
    if (program == nullptr || program->vertexLayouts.empty() ||
        program->vertexAttributes.empty() ||
        streams.size() != program->vertexLayouts.size() ||
        !conformsToMetalProtocol(library_handle, @protocol(MTLLibrary)))
    {
        return std::nullopt;
    }

    id<MTLLibrary> native_library =
        (__bridge id<MTLLibrary>)library_handle;
    id<MTLDevice> native_device = native_library.device;
    if (native_device == nil)
    {
        return std::nullopt;
    }

    std::vector<bool> consumed(streams.size(), false);
    std::vector<OwnedVertexStream> owned_streams;
    owned_streams.reserve(program->vertexLayouts.size());
    for (const MetalVertexBufferLayoutDescriptor& layout : program->vertexLayouts)
    {
        const auto requirement = streamRequirement(*program, layout);
        if (!requirement)
        {
            return std::nullopt;
        }

        std::size_t match = streams.size();
        for (std::size_t index = 0; index < streams.size(); ++index)
        {
            if (streams[index].bufferIndex == layout.bufferIndex)
            {
                if (match != streams.size())
                {
                    return std::nullopt;
                }
                match = index;
            }
        }
        if (match == streams.size() || consumed[match])
        {
            return std::nullopt;
        }

        MetalVertexStreamBinding& binding = streams[match];
        id<MTLBuffer> native_buffer = nil;
        std::size_t minimum_size = 0;
        if (binding.offset % requirement->alignment != 0 ||
            !checkedAdd(binding.offset,
                        requirement->extent,
                        minimum_size) ||
            minimum_size > binding.buffer.size() ||
            !validPrivateBuffer(binding.buffer,
                                native_device,
                                native_buffer))
        {
            return std::nullopt;
        }
        consumed[match] = true;
        owned_streams.push_back(OwnedVertexStream{
            layout.bufferIndex,
            requirement->stride,
            requirement->extent,
            std::move(binding.buffer),
            binding.offset,
        });
    }
    if (std::find(consumed.begin(), consumed.end(), false) != consumed.end())
    {
        return std::nullopt;
    }

    auto impl = std::make_shared<const MetalArtifactGeometry::Impl>(
        native_device,
        native_library,
        program->id,
        std::string(program->reflectionSha256),
        std::move(owned_streams));
    return MetalArtifactGeometry(std::move(impl));
}

MetalDrawStatus
encodeArtifactTriangles(MetalRenderEncoderHandle encoder,
                        const MetalArtifactPipeline& pipeline,
                        const MetalArtifactGeometry& geometry,
                        std::size_t first_vertex,
                        std::size_t vertex_count) noexcept
{
    if (!geometry.valid())
    {
        return MetalDrawStatus::invalid_state;
    }
    if (!validVertexRange(geometry.mImpl->streams,
                          first_vertex,
                          vertex_count))
    {
        return MetalDrawStatus::invalid_argument;
    }
    const auto preflight = preflightEncoder(
        encoder,
        pipeline,
        geometry.mImpl->device,
        geometry.mImpl->library,
        geometry.mImpl->programId,
        geometry.mImpl->reflectionSha256,
        geometry.mImpl->streams);
    if (!preflight)
    {
        return MetalDrawStatus::invalid_state;
    }

    bindPipelineAndStreams(*preflight, geometry.mImpl->streams);
    [preflight->encoder drawPrimitives:MTLPrimitiveTypeTriangle
                            vertexStart:first_vertex
                            vertexCount:vertex_count];
    return MetalDrawStatus::encoded;
}

MetalDrawStatus
encodeArtifactIndexedTriangles(MetalRenderEncoderHandle encoder,
                               const MetalArtifactPipeline& pipeline,
                               const MetalArtifactGeometry& geometry,
                               const MetalIndexBufferBinding& indices,
                               std::size_t first_index,
                               std::size_t index_count) noexcept
{
    if (!geometry.valid())
    {
        return MetalDrawStatus::invalid_state;
    }
    const auto index_type = nativeIndexType(indices.type);
    if (!index_type || index_count == 0 || index_count % 3 != 0 ||
        indices.offset % (index_type ? index_type->first : 1) != 0)
    {
        return MetalDrawStatus::invalid_argument;
    }

    std::size_t first_index_bytes = 0;
    std::size_t index_bytes = 0;
    std::size_t native_offset = 0;
    std::size_t native_end = 0;
    if (!checkedMultiply(first_index, index_type->first, first_index_bytes) ||
        !checkedMultiply(index_count, index_type->first, index_bytes) ||
        !checkedAdd(indices.offset, first_index_bytes, native_offset) ||
        !checkedAdd(native_offset, index_bytes, native_end) ||
        native_end > indices.buffer.size())
    {
        return MetalDrawStatus::invalid_argument;
    }

    id<MTLBuffer> native_indices = nil;
    if (!validPrivateBuffer(indices.buffer,
                            geometry.mImpl->device,
                            native_indices))
    {
        return MetalDrawStatus::invalid_argument;
    }
    const auto preflight = preflightEncoder(
        encoder,
        pipeline,
        geometry.mImpl->device,
        geometry.mImpl->library,
        geometry.mImpl->programId,
        geometry.mImpl->reflectionSha256,
        geometry.mImpl->streams);
    if (!preflight)
    {
        return MetalDrawStatus::invalid_state;
    }

    bindPipelineAndStreams(*preflight, geometry.mImpl->streams);
    [preflight->encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                   indexCount:index_count
                                    indexType:index_type->second
                                  indexBuffer:native_indices
                            indexBufferOffset:native_offset];
    return MetalDrawStatus::encoded;
}

} // namespace firestorm::metal
