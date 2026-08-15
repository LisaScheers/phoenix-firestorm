/**
 * @file artifact-vertex-index-test-objc.mm
 * @brief Exact ui_font artifact vertex-layout and indexed-draw validation.
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

#include "firestorm-declared-programs.h"
#include "llmetalgeometry.h"
#include "llmetalrenderpass.h"
#include "llmetaltransfer.h"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

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

using firestorm::metal::AttachmentLoadAction;
using firestorm::metal::AttachmentStoreAction;
using firestorm::metal::BlendAttachmentDesc;
using firestorm::metal::BlendOperation;
using firestorm::metal::MetalArtifactGeometry;
using firestorm::metal::MetalArtifactPipeline;
using firestorm::metal::MetalBufferReadback;
using firestorm::metal::MetalByteView;
using firestorm::metal::MetalClearColor;
using firestorm::metal::MetalColorAttachmentDesc;
using firestorm::metal::MetalDrawStatus;
using firestorm::metal::MetalFrameContext;
using firestorm::metal::MetalIndexBufferBinding;
using firestorm::metal::MetalIndexType;
using firestorm::metal::MetalPrivateBuffer;
using firestorm::metal::MetalPrivateTexture;
using firestorm::metal::MetalProgramDescriptor;
using firestorm::metal::MetalProgramId;
using firestorm::metal::MetalProgramLibrary;
using firestorm::metal::MetalRenderPassDesc;
using firestorm::metal::MetalRenderPipelineFamilyCache;
using firestorm::metal::MetalRenderTarget;
using firestorm::metal::MetalTextureDescriptor;
using firestorm::metal::MetalTextureReadback;
using firestorm::metal::MetalTextureRegion;
using firestorm::metal::MetalTextureSubresourceUpload;
using firestorm::metal::MetalTextureType;
using firestorm::metal::MetalTextureDataType;
using firestorm::metal::MetalTextureUsage;
using firestorm::metal::MetalTransferBatch;
using firestorm::metal::MetalTransferStatus;
using firestorm::metal::MetalVertexFormat;
using firestorm::metal::MetalVertexStepFunction;
using firestorm::metal::MetalVertexStreamBinding;
using firestorm::metal::PixelFormat;
using firestorm::metal::beginRenderPass;
using firestorm::metal::createPrivateTexture;
using firestorm::metal::encodeArtifactIndexedTriangles;
using firestorm::metal::encodeArtifactTriangles;
using firestorm::metal::makeArtifactGeometry;
using firestorm::metal::makeRenderTarget;

constexpr std::uint32_t WIDTH = 6;
constexpr std::uint32_t HEIGHT = 4;
constexpr std::size_t BYTES_PER_PIXEL = 4;
constexpr std::size_t READBACK_ROW_BYTES = 256;
constexpr std::size_t READBACK_BYTES = READBACK_ROW_BYTES * HEIGHT;
constexpr std::size_t PREFIX_VERTICES = 4;
constexpr std::size_t VERTEX_COUNT = 15;
constexpr std::size_t PUBLICATION_COUNT = 7;

struct Position
{
    float x;
    float y;
    float z;
    float padding;
};

struct Texcoord
{
    float u;
    float v;
};

struct Color
{
    std::uint8_t red;
    std::uint8_t green;
    std::uint8_t blue;
    std::uint8_t alpha;
};

// This exact reflected ui_font fixture is deliberately test-only. General
// artifact-driven uniform packing remains deferred from the geometry slice.
struct alignas(16) UiFontIdentityUniforms
{
    float textureMatrix[16];
    float modelViewProjectionMatrix[16];
};

static_assert(sizeof(Position) == 16);
static_assert(sizeof(Texcoord) == 8);
static_assert(sizeof(Color) == 4);
static_assert(sizeof(UiFontIdentityUniforms) == 128);

struct UiFontSemantics
{
    std::uint8_t positionBuffer = 0;
    std::uint8_t texcoordBuffer = 0;
    std::uint8_t colorBuffer = 0;
    std::uint8_t uniformBuffer = 0;
    std::uint32_t uniformSize = 0;
    std::uint16_t uniformAlignment = 0;
    std::uint8_t textureIndex = 0;
    std::uint8_t samplerIndex = 0;
};

struct UploadedResources
{
    std::optional<MetalPrivateBuffer> positions;
    std::optional<MetalPrivateBuffer> texcoords;
    std::optional<MetalPrivateBuffer> colors;
    std::optional<MetalPrivateBuffer> indices16;
    std::optional<MetalPrivateBuffer> indices32;
    std::optional<MetalPrivateBuffer> uniforms;
    std::optional<MetalPrivateTexture> whiteTexture;
    std::uint64_t submissionSerial = 0;
};

struct UploadState
{
    std::mutex mutex;
    UploadedResources resources;
    std::vector<std::uint64_t> serials;
    std::size_t count = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
};

bool parseOptions(int argc, const char* argv[], std::string& metallib_path)
{
    if (argc == 3 && std::string(argv[1]) == "--metallib")
    {
        metallib_path = argv[2];
        return !metallib_path.empty();
    }
    std::cerr << "Usage: " << argv[0] << " --metallib PATH\n";
    return false;
}

std::string toString(NSString* value)
{
    if (value == nil)
    {
        return {};
    }
    const char* utf8 = value.UTF8String;
    return utf8 == nullptr ? std::string{} : std::string(utf8);
}

std::string commandError(id<MTLCommandBuffer> command_buffer)
{
    return command_buffer == nil || command_buffer.error == nil
        ? std::string{}
        : toString(command_buffer.error.localizedDescription);
}

void requireSignal(dispatch_semaphore_t semaphore,
                   id<MTLCommandBuffer> command_buffer,
                   const char* operation)
{
    if (dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0)
    {
        return;
    }
    std::cerr << "TIMEOUT waiting for " << operation
              << " status=" << static_cast<unsigned long>(command_buffer.status)
              << " error=\"" << commandError(command_buffer) << "\"\n";
    std::_Exit(EXIT_FAILURE);
}

MetalByteView byteView(const void* data, std::size_t size)
{
    return MetalByteView{ static_cast<const std::byte*>(data), size };
}

std::array<Position, PREFIX_VERTICES + VERTEX_COUNT> positionFixture()
{
    std::array<Position, PREFIX_VERTICES + VERTEX_COUNT> result{};
    for (std::size_t index = 0; index < PREFIX_VERTICES; ++index)
    {
        result[index] = Position{ 2.0F, 2.0F, 0.0F, 91.0F };
    }
    constexpr std::array<Position, 3> triangle{
        Position{ -1.0F, -1.0F, 0.0F, 0.0F },
        Position{ 3.0F, -1.0F, 0.0F, 0.0F },
        Position{ -1.0F, 3.0F, 0.0F, 0.0F },
    };
    for (std::size_t vertex = 0; vertex < VERTEX_COUNT; ++vertex)
    {
        result[PREFIX_VERTICES + vertex] = triangle[vertex % triangle.size()];
    }
    return result;
}

std::array<Texcoord, PREFIX_VERTICES + VERTEX_COUNT> texcoordFixture()
{
    std::array<Texcoord, PREFIX_VERTICES + VERTEX_COUNT> result{};
    for (std::size_t index = 0; index < PREFIX_VERTICES; ++index)
    {
        result[index] = Texcoord{ 99.0F, -99.0F };
    }
    for (std::size_t vertex = 0; vertex < VERTEX_COUNT; ++vertex)
    {
        result[PREFIX_VERTICES + vertex] = Texcoord{ 0.25F, 0.5F };
    }
    return result;
}

std::array<Color, PREFIX_VERTICES + VERTEX_COUNT> colorFixture()
{
    std::array<Color, PREFIX_VERTICES + VERTEX_COUNT> result{};
    for (std::size_t index = 0; index < PREFIX_VERTICES; ++index)
    {
        result[index] = Color{ 0, 255, 255, 255 };
    }
    constexpr std::array<Color, 5> colors{
        Color{ 255, 0, 0, 255 },
        Color{ 0, 255, 0, 255 },
        Color{ 255, 0, 255, 255 },
        Color{ 0, 0, 255, 255 },
        Color{ 255, 255, 0, 255 },
    };
    for (std::size_t group = 0; group < colors.size(); ++group)
    {
        for (std::size_t vertex = 0; vertex < 3; ++vertex)
        {
            result[PREFIX_VERTICES + group * 3 + vertex] = colors[group];
        }
    }
    return result;
}

UiFontIdentityUniforms identityUniforms()
{
    UiFontIdentityUniforms result{};
    for (std::size_t diagonal = 0; diagonal < 4; ++diagonal)
    {
        result.textureMatrix[diagonal * 5] = 1.0F;
        result.modelViewProjectionMatrix[diagonal * 5] = 1.0F;
    }
    return result;
}

constexpr std::array<std::uint16_t, 16> INDICES16{
    12, 13, 14, 12,
    12, 13, 14, 12,
    3, 4, 5, 0,
    9, 10, 11, 0,
};

constexpr std::array<std::uint32_t, 12> INDICES32{
    3, 4, 5, 3,
    9, 10, 11, 9,
    6, 7, 8, 0,
};

std::optional<UiFontSemantics>
inspectUiFont(const MetalProgramLibrary& library)
{
    const MetalProgramDescriptor* program = library.program(MetalProgramId::ui_font);
    EXPECT(program != nullptr);
    if (program == nullptr)
    {
        return std::nullopt;
    }

    EXPECT(program->name == "ui_font");
    EXPECT(program->vertexFunction == "ui_font_vertex");
    EXPECT(program->fragmentFunction == "ui_font_fragment");
    EXPECT(program->colorFormats.size() == 1);
    EXPECT(program->colorFormats.size() == 1 &&
           program->colorFormats[0] == PixelFormat::bgra8_unorm);
    EXPECT(!program->depthFormat.has_value());
    EXPECT(program->sampleCount == 1);
    EXPECT(program->vertexAttributes.size() == 3);
    EXPECT(program->vertexLayouts.size() == 3);
    EXPECT(program->vertexBindings.buffers.size() == 1);
    EXPECT(program->fragmentBindings.textures.size() == 1);
    EXPECT(program->fragmentBindings.samplers.size() == 1);

    UiFontSemantics result;
    bool position_found = false;
    bool texcoord_found = false;
    bool color_found = false;
    for (const auto& attribute : program->vertexAttributes)
    {
        EXPECT(attribute.offset == 0);
        if (attribute.name == "position")
        {
            EXPECT(attribute.location == 0);
            EXPECT(attribute.format == MetalVertexFormat::float32x3);
            result.positionBuffer = attribute.bufferIndex;
            position_found = true;
        }
        else if (attribute.name == "texcoord0")
        {
            EXPECT(attribute.location == 2);
            EXPECT(attribute.format == MetalVertexFormat::float32x2);
            result.texcoordBuffer = attribute.bufferIndex;
            texcoord_found = true;
        }
        else if (attribute.name == "diffuse_color")
        {
            EXPECT(attribute.location == 6);
            EXPECT(attribute.format == MetalVertexFormat::uint8x4_normalized);
            result.colorBuffer = attribute.bufferIndex;
            color_found = true;
        }
    }
    EXPECT(position_found && texcoord_found && color_found);
    EXPECT(result.positionBuffer == 16);
    EXPECT(result.texcoordBuffer == 18);
    EXPECT(result.colorBuffer == 20);

    for (const auto& layout : program->vertexLayouts)
    {
        EXPECT(layout.stepFunction == MetalVertexStepFunction::per_vertex);
        if (layout.bufferIndex == result.positionBuffer)
        {
            EXPECT(layout.stride == sizeof(Position));
        }
        else if (layout.bufferIndex == result.texcoordBuffer)
        {
            EXPECT(layout.stride == sizeof(Texcoord));
        }
        else if (layout.bufferIndex == result.colorBuffer)
        {
            EXPECT(layout.stride == sizeof(Color));
        }
        else
        {
            EXPECT(false);
        }
    }

    if (!program->vertexBindings.buffers.empty())
    {
        const auto& uniform = program->vertexBindings.buffers[0];
        EXPECT(uniform.name == "FirestormVertexUniforms");
        result.uniformBuffer = uniform.index;
        result.uniformSize = uniform.size;
        result.uniformAlignment = uniform.alignment;
        EXPECT(result.uniformBuffer == 24);
        EXPECT(result.uniformSize == sizeof(UiFontIdentityUniforms));
        EXPECT(result.uniformAlignment == alignof(UiFontIdentityUniforms));
    }
    if (!program->fragmentBindings.textures.empty())
    {
        const auto& texture = program->fragmentBindings.textures[0];
        EXPECT(texture.name == "diffuseMap");
        EXPECT(texture.type == MetalTextureType::texture_2d);
        EXPECT(texture.dataType == MetalTextureDataType::float32);
        EXPECT(texture.arrayLength == 1);
        EXPECT(!texture.depth);
        result.textureIndex = texture.index;
    }
    if (!program->fragmentBindings.samplers.empty())
    {
        const auto& sampler = program->fragmentBindings.samplers[0];
        EXPECT(sampler.name == "diffuseMap");
        result.samplerIndex = sampler.index;
    }
    EXPECT(result.textureIndex == 0);
    EXPECT(result.samplerIndex == 0);
    return result;
}

std::size_t uploadPublicationCount(UploadState& state)
{
    std::lock_guard<std::mutex> lock(state.mutex);
    return state.count;
}

std::optional<UploadedResources>
uploadResources(id<MTLDevice> device,
                id<MTLCommandQueue> queue,
                MetalFrameContext& frames)
{
    const auto positions = positionFixture();
    const auto texcoords = texcoordFixture();
    const auto colors = colorFixture();
    const auto uniforms = identityUniforms();
    constexpr std::array<std::uint8_t, 8> white_and_poison{
        255, 255, 255, 255,
        0, 0, 0, 255,
    };

    const auto lease = frames.tryBegin();
    EXPECT(lease.has_value());
    if (!lease)
    {
        return std::nullopt;
    }
    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    EXPECT(command_buffer != nil);
    if (command_buffer == nil)
    {
        EXPECT(frames.cancel(lease->token));
        return std::nullopt;
    }
    command_buffer.label = @"Firestorm ui_font artifact geometry uploads";

    UploadState state;
    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             0);
    EXPECT(batch.valid());
    if (!batch.valid())
    {
        return std::nullopt;
    }

    using BufferMember = std::optional<MetalPrivateBuffer> UploadedResources::*;
    const auto publish_buffer = [&](BufferMember member) {
        return [&, member](std::uint64_t serial, MetalPrivateBuffer buffer) {
            bool finished = false;
            {
                std::lock_guard<std::mutex> lock(state.mutex);
                state.resources.*member = std::move(buffer);
                state.serials.push_back(serial);
                ++state.count;
                finished = state.count == PUBLICATION_COUNT;
            }
            if (finished)
            {
                dispatch_semaphore_signal(state.done);
            }
        };
    };

    bool encoded = true;
    encoded = batch.uploadPrivateBuffer(
                  byteView(positions.data(), sizeof(positions)),
                  "Firestorm ui_font positions with poison prefix",
                  publish_buffer(&UploadedResources::positions)) ==
              MetalTransferStatus::encoded && encoded;
    encoded = batch.uploadPrivateBuffer(
                  byteView(texcoords.data(), sizeof(texcoords)),
                  "Firestorm ui_font texcoords with poison prefix",
                  publish_buffer(&UploadedResources::texcoords)) ==
              MetalTransferStatus::encoded && encoded;
    encoded = batch.uploadPrivateBuffer(
                  byteView(colors.data(), sizeof(colors)),
                  "Firestorm ui_font colors with poison prefix",
                  publish_buffer(&UploadedResources::colors)) ==
              MetalTransferStatus::encoded && encoded;
    encoded = batch.uploadPrivateBuffer(
                  byteView(INDICES16.data(), sizeof(INDICES16)),
                  "Firestorm ui_font U16 indices with poison prefix",
                  publish_buffer(&UploadedResources::indices16)) ==
              MetalTransferStatus::encoded && encoded;
    encoded = batch.uploadPrivateBuffer(
                  byteView(INDICES32.data(), sizeof(INDICES32)),
                  "Firestorm ui_font U32 indices with poison prefix",
                  publish_buffer(&UploadedResources::indices32)) ==
              MetalTransferStatus::encoded && encoded;
    encoded = batch.uploadPrivateBuffer(
                  byteView(&uniforms, sizeof(uniforms)),
                  "Firestorm ui_font identity uniform fixture",
                  publish_buffer(&UploadedResources::uniforms)) ==
              MetalTransferStatus::encoded && encoded;

    MetalTextureDescriptor texture_descriptor;
    texture_descriptor.format = PixelFormat::rgba8_unorm;
    texture_descriptor.width = 2;
    texture_descriptor.height = 1;
    texture_descriptor.mipLevels = 1;
    texture_descriptor.usage = MetalTextureUsage::shader_read;
    texture_descriptor.label = "Firestorm ui_font white/poison texture";
    const std::vector<MetalTextureSubresourceUpload> texture_uploads{
        MetalTextureSubresourceUpload{
            0,
            0,
            byteView(white_and_poison.data(), white_and_poison.size()),
            white_and_poison.size(),
        },
    };
    encoded = batch.uploadPrivateTexture(
                  texture_descriptor,
                  texture_uploads,
                  [&](std::uint64_t serial, MetalPrivateTexture texture) {
                      bool finished = false;
                      {
                          std::lock_guard<std::mutex> lock(state.mutex);
                          state.resources.whiteTexture = std::move(texture);
                          state.serials.push_back(serial);
                          ++state.count;
                          finished = state.count == PUBLICATION_COUNT;
                      }
                      if (finished)
                      {
                          dispatch_semaphore_signal(state.done);
                      }
                  }) == MetalTransferStatus::encoded && encoded;
    EXPECT(encoded);
    if (!encoded)
    {
        batch.cancel();
        return std::nullopt;
    }

    auto completion = batch.finish();
    EXPECT(completion.has_value());
    if (!completion)
    {
        return std::nullopt;
    }
    EXPECT(uploadPublicationCount(state) == 0);
    const auto serial = frames.submit(lease->token,
                                      (__bridge void*)command_buffer,
                                      std::move(*completion));
    EXPECT(serial.has_value());
    if (!serial)
    {
        EXPECT(frames.cancel(lease->token));
        return std::nullopt;
    }
    EXPECT(uploadPublicationCount(state) == 0);
    [command_buffer commit];
    requireSignal(state.done, command_buffer, "ui_font private uploads");
    EXPECT(command_buffer.status == MTLCommandBufferStatusCompleted);
    EXPECT(command_buffer.error == nil);

    std::lock_guard<std::mutex> lock(state.mutex);
    EXPECT(state.count == PUBLICATION_COUNT);
    EXPECT(state.serials.size() == PUBLICATION_COUNT);
    for (std::uint64_t publication_serial : state.serials)
    {
        EXPECT(publication_serial == *serial);
    }
    state.resources.submissionSerial = *serial;
    EXPECT(state.resources.positions.has_value());
    EXPECT(state.resources.texcoords.has_value());
    EXPECT(state.resources.colors.has_value());
    EXPECT(state.resources.indices16.has_value());
    EXPECT(state.resources.indices32.has_value());
    EXPECT(state.resources.uniforms.has_value());
    EXPECT(state.resources.whiteTexture.has_value());
    if (!state.resources.positions || !state.resources.texcoords ||
        !state.resources.colors || !state.resources.indices16 ||
        !state.resources.indices32 || !state.resources.uniforms ||
        !state.resources.whiteTexture)
    {
        return std::nullopt;
    }
    id<MTLTexture> native_texture =
        (__bridge id<MTLTexture>)state.resources.whiteTexture->nativeHandle();
    EXPECT(native_texture != nil);
    EXPECT(native_texture.width == 2);
    EXPECT(native_texture.height == 1);
    EXPECT(native_texture.storageMode == MTLStorageModePrivate);
    return state.resources;
}

std::vector<MetalVertexStreamBinding>
validStreams(const UploadedResources& resources,
             const UiFontSemantics& semantics)
{
    return {
        MetalVertexStreamBinding{
            semantics.colorBuffer,
            *resources.colors,
            PREFIX_VERTICES * sizeof(Color),
        },
        MetalVertexStreamBinding{
            semantics.positionBuffer,
            *resources.positions,
            PREFIX_VERTICES * sizeof(Position),
        },
        MetalVertexStreamBinding{
            semantics.texcoordBuffer,
            *resources.texcoords,
            PREFIX_VERTICES * sizeof(Texcoord),
        },
    };
}

std::optional<MetalArtifactGeometry>
testGeometryValidation(const MetalProgramLibrary& library,
                       const UploadedResources& resources,
                       const UiFontSemantics& semantics)
{
    const auto valid = validStreams(resources, semantics);
    EXPECT(!makeArtifactGeometry(library,
                                 MetalProgramId::ui_font,
                                 {}).has_value());
    EXPECT(!makeArtifactGeometry(library,
                                 static_cast<MetalProgramId>(0),
                                 valid).has_value());

    auto missing = valid;
    missing.pop_back();
    EXPECT(!makeArtifactGeometry(library,
                                 MetalProgramId::ui_font,
                                 missing).has_value());

    auto extra = valid;
    extra.push_back(MetalVertexStreamBinding{
        30,
        *resources.positions,
        PREFIX_VERTICES * sizeof(Position),
    });
    EXPECT(!makeArtifactGeometry(library,
                                 MetalProgramId::ui_font,
                                 extra).has_value());

    auto duplicate = valid;
    duplicate[0].bufferIndex = duplicate[1].bufferIndex;
    EXPECT(!makeArtifactGeometry(library,
                                 MetalProgramId::ui_font,
                                 duplicate).has_value());

    auto empty_buffer = valid;
    empty_buffer[0].buffer = MetalPrivateBuffer{};
    EXPECT(!makeArtifactGeometry(library,
                                 MetalProgramId::ui_font,
                                 empty_buffer).has_value());

    auto misaligned_position = valid;
    misaligned_position[1].offset += 1;
    EXPECT(!makeArtifactGeometry(library,
                                 MetalProgramId::ui_font,
                                 misaligned_position).has_value());

    auto misaligned_texcoord = valid;
    misaligned_texcoord[2].offset += 2;
    EXPECT(!makeArtifactGeometry(library,
                                 MetalProgramId::ui_font,
                                 misaligned_texcoord).has_value());

    auto no_complete_position = valid;
    no_complete_position[1].offset = resources.positions->size() - 8;
    EXPECT(!makeArtifactGeometry(library,
                                 MetalProgramId::ui_font,
                                 no_complete_position).has_value());

    auto offset_at_end = valid;
    offset_at_end[0].offset = resources.colors->size();
    EXPECT(!makeArtifactGeometry(library,
                                 MetalProgramId::ui_font,
                                 offset_at_end).has_value());

    auto overflowing_offset = valid;
    overflowing_offset[1].offset =
        std::numeric_limits<std::size_t>::max() - 3;
    EXPECT(!makeArtifactGeometry(library,
                                 MetalProgramId::ui_font,
                                 overflowing_offset).has_value());

    EXPECT(!makeArtifactGeometry(library,
                                 MetalProgramId::reflection_probe,
                                 valid).has_value());

    auto geometry = makeArtifactGeometry(library,
                                         MetalProgramId::ui_font,
                                         valid);
    EXPECT(geometry.has_value());
    EXPECT(geometry && geometry->valid());
    EXPECT(geometry && geometry->streamCount() == 3);
    return geometry;
}

std::optional<MetalArtifactPipeline>
testPipelineCache(MetalRenderPipelineFamilyCache& cache)
{
    EXPECT(cache.valid());
    EXPECT(cache.hitCount() == 0);
    EXPECT(cache.missCount() == 0);
    EXPECT(cache.entryCount() == 0);
    EXPECT(!cache.artifactPipeline({}).has_value());

    BlendAttachmentDesc invalid;
    invalid.writeMask = static_cast<firestorm::metal::ColorWriteMask>(16);
    EXPECT(!cache.artifactPipeline({ invalid }).has_value());
    EXPECT(cache.hitCount() == 0);
    EXPECT(cache.missCount() == 0);
    EXPECT(cache.entryCount() == 0);

    const BlendAttachmentDesc default_blend;
    auto pipeline = cache.artifactPipeline({ default_blend });
    EXPECT(pipeline.has_value());
    EXPECT(pipeline && pipeline->valid());
    EXPECT(cache.hitCount() == 0);
    EXPECT(cache.missCount() == 1);
    EXPECT(cache.entryCount() == 1);

    BlendAttachmentDesc canonical_equivalent;
    canonical_equivalent.rgbOperation = BlendOperation::max;
    auto equivalent = cache.artifactPipeline({ canonical_equivalent });
    EXPECT(equivalent.has_value());
    EXPECT(pipeline && equivalent &&
           pipeline->nativeHandle() == equivalent->nativeHandle());
    EXPECT(cache.hitCount() == 1);
    EXPECT(cache.missCount() == 1);
    EXPECT(cache.entryCount() == 1);

    const auto raw = cache.pipeline({ default_blend });
    EXPECT(raw.has_value());
    EXPECT(pipeline && raw && *raw == pipeline->nativeHandle());
    EXPECT(cache.hitCount() == 2);
    EXPECT(cache.missCount() == 1);
    EXPECT(cache.entryCount() == 1);
    return pipeline;
}

std::optional<MetalRenderTarget> createTarget(id<MTLDevice> device,
                                               MetalPrivateTexture& color)
{
    MetalTextureDescriptor descriptor;
    descriptor.format = PixelFormat::bgra8_unorm;
    descriptor.width = WIDTH;
    descriptor.height = HEIGHT;
    descriptor.mipLevels = 1;
    descriptor.usage = MetalTextureUsage::render_target;
    descriptor.label = "Firestorm ui_font 6x4 artifact target";
    const auto created = createPrivateTexture((__bridge void*)device, descriptor);
    EXPECT(created.has_value());
    if (!created)
    {
        return std::nullopt;
    }
    color = *created;
    return makeRenderTarget({ color });
}

void validateReadback(const MetalTextureReadback& readback)
{
    EXPECT(readback.format == PixelFormat::bgra8_unorm);
    EXPECT(readback.region.x == 0);
    EXPECT(readback.region.y == 0);
    EXPECT(readback.region.width == WIDTH);
    EXPECT(readback.region.height == HEIGHT);
    EXPECT(readback.region.mipLevel == 0);
    EXPECT(readback.region.slice == 0);
    EXPECT(readback.bytesPerRow == READBACK_ROW_BYTES);
    EXPECT(readback.bytesPerImage == READBACK_BYTES);
    EXPECT(readback.bytes.size() == READBACK_BYTES);
    if (readback.bytes.size() < READBACK_BYTES)
    {
        return;
    }

    constexpr std::array<std::array<std::uint8_t, 4>, WIDTH> TOP{
        std::array<std::uint8_t, 4>{ 0, 0, 255, 255 },
        std::array<std::uint8_t, 4>{ 0, 0, 255, 255 },
        std::array<std::uint8_t, 4>{ 0, 255, 0, 255 },
        std::array<std::uint8_t, 4>{ 0, 255, 0, 255 },
        std::array<std::uint8_t, 4>{ 255, 0, 255, 255 },
        std::array<std::uint8_t, 4>{ 255, 0, 255, 255 },
    };
    constexpr std::array<std::array<std::uint8_t, 4>, WIDTH> BOTTOM{
        std::array<std::uint8_t, 4>{ 255, 0, 0, 255 },
        std::array<std::uint8_t, 4>{ 255, 0, 0, 255 },
        std::array<std::uint8_t, 4>{ 0, 255, 255, 255 },
        std::array<std::uint8_t, 4>{ 0, 255, 255, 255 },
        std::array<std::uint8_t, 4>{ 0, 0, 0, 255 },
        std::array<std::uint8_t, 4>{ 0, 0, 0, 255 },
    };

    for (std::size_t y = 0; y < HEIGHT; ++y)
    {
        const auto& expected_row = y < 2 ? TOP : BOTTOM;
        for (std::size_t x = 0; x < WIDTH; ++x)
        {
            for (std::size_t channel = 0; channel < BYTES_PER_PIXEL; ++channel)
            {
                const std::size_t offset =
                    y * readback.bytesPerRow + x * BYTES_PER_PIXEL + channel;
                const std::uint8_t actual =
                    std::to_integer<std::uint8_t>(readback.bytes[offset]);
                if (actual != expected_row[x][channel])
                {
                    std::cerr << "FAIL ui_font pixel=(" << x << ',' << y
                              << ") BGRA-channel=" << channel
                              << " expected="
                              << static_cast<unsigned>(expected_row[x][channel])
                              << " actual=" << static_cast<unsigned>(actual)
                              << " bytesPerRow=" << readback.bytesPerRow << '\n';
                    ++gFailures;
                    return;
                }
            }
        }
    }
}

void testDrawRejections(id<MTLDevice> device,
                        const std::string& metallib_path,
                        const MetalProgramLibrary& library,
                        const UploadedResources& resources,
                        const UiFontSemantics& semantics,
                        void* encoder,
                        const MetalArtifactPipeline& pipeline,
                        const MetalArtifactGeometry& geometry)
{
    EXPECT(encodeArtifactTriangles(nullptr,
                                   pipeline,
                                   geometry,
                                   0,
                                   3) == MetalDrawStatus::invalid_state);
    NSObject* wrong_encoder = [[NSObject alloc] init];
    EXPECT(encodeArtifactTriangles((__bridge void*)wrong_encoder,
                                   pipeline,
                                   geometry,
                                   0,
                                   3) == MetalDrawStatus::invalid_state);
    EXPECT(encodeArtifactTriangles(encoder,
                                   pipeline,
                                   MetalArtifactGeometry{},
                                   0,
                                   3) == MetalDrawStatus::invalid_state);
    EXPECT(encodeArtifactTriangles(encoder,
                                   pipeline,
                                   geometry,
                                   0,
                                   0) == MetalDrawStatus::invalid_argument);
    EXPECT(encodeArtifactTriangles(encoder,
                                   pipeline,
                                   geometry,
                                   0,
                                   2) == MetalDrawStatus::invalid_argument);
    EXPECT(encodeArtifactTriangles(encoder,
                                   pipeline,
                                   geometry,
                                   VERTEX_COUNT,
                                   3) == MetalDrawStatus::invalid_argument);
    EXPECT(encodeArtifactTriangles(
               encoder,
               pipeline,
               geometry,
               std::numeric_limits<std::size_t>::max() - 1,
               3) == MetalDrawStatus::invalid_argument);

    const MetalIndexBufferBinding valid16{
        *resources.indices16,
        4 * sizeof(std::uint16_t),
        MetalIndexType::uint16,
    };
    const MetalIndexBufferBinding valid32{
        *resources.indices32,
        4 * sizeof(std::uint32_t),
        MetalIndexType::uint32,
    };
    MetalIndexBufferBinding invalid = valid16;
    invalid.type = static_cast<MetalIndexType>(255);
    EXPECT(encodeArtifactIndexedTriangles(encoder,
                                          pipeline,
                                          geometry,
                                          invalid,
                                          4,
                                          3) == MetalDrawStatus::invalid_argument);
    invalid = valid16;
    invalid.buffer = MetalPrivateBuffer{};
    EXPECT(encodeArtifactIndexedTriangles(encoder,
                                          pipeline,
                                          geometry,
                                          invalid,
                                          4,
                                          3) == MetalDrawStatus::invalid_argument);
    invalid = valid16;
    invalid.offset = 1;
    EXPECT(encodeArtifactIndexedTriangles(encoder,
                                          pipeline,
                                          geometry,
                                          invalid,
                                          4,
                                          3) == MetalDrawStatus::invalid_argument);
    invalid = valid32;
    invalid.offset = 2;
    EXPECT(encodeArtifactIndexedTriangles(encoder,
                                          pipeline,
                                          geometry,
                                          invalid,
                                          4,
                                          3) == MetalDrawStatus::invalid_argument);
    invalid = valid16;
    invalid.offset = resources.indices16->size();
    EXPECT(encodeArtifactIndexedTriangles(encoder,
                                          pipeline,
                                          geometry,
                                          invalid,
                                          0,
                                          3) == MetalDrawStatus::invalid_argument);
    EXPECT(encodeArtifactIndexedTriangles(
               encoder,
               pipeline,
               geometry,
               valid16,
               std::numeric_limits<std::size_t>::max(),
               3) == MetalDrawStatus::invalid_argument);
    EXPECT(encodeArtifactIndexedTriangles(
               encoder,
               pipeline,
               geometry,
               valid16,
               0,
               std::numeric_limits<std::size_t>::max()) ==
           MetalDrawStatus::invalid_argument);
    EXPECT(encodeArtifactIndexedTriangles(encoder,
                                          pipeline,
                                          geometry,
                                          valid16,
                                          0,
                                          0) == MetalDrawStatus::invalid_argument);
    EXPECT(encodeArtifactIndexedTriangles(encoder,
                                          pipeline,
                                          geometry,
                                          valid16,
                                          0,
                                          2) == MetalDrawStatus::invalid_argument);

    MetalRenderPipelineFamilyCache other_program_cache(
        library,
        MetalProgramId::reflection_probe);
    EXPECT(other_program_cache.valid());
    const auto other_program_pipeline =
        other_program_cache.artifactPipeline({ BlendAttachmentDesc{} });
    EXPECT(other_program_pipeline.has_value());
    if (other_program_pipeline)
    {
        EXPECT(encodeArtifactTriangles(encoder,
                                       *other_program_pipeline,
                                       geometry,
                                       0,
                                       3) == MetalDrawStatus::invalid_state);
    }

    MetalProgramLibrary other_library((__bridge void*)device, metallib_path);
    EXPECT(other_library.valid());
    MetalRenderPipelineFamilyCache other_library_cache(other_library,
                                                        MetalProgramId::ui_font);
    EXPECT(other_library_cache.valid());
    const auto other_library_pipeline =
        other_library_cache.artifactPipeline({ BlendAttachmentDesc{} });
    const auto other_library_geometry = makeArtifactGeometry(
        other_library,
        MetalProgramId::ui_font,
        validStreams(resources, semantics));
    EXPECT(other_library_pipeline.has_value());
    EXPECT(other_library_geometry.has_value());
    if (other_library.nativeLibrary() != library.nativeLibrary())
    {
        if (other_library_pipeline)
        {
            EXPECT(encodeArtifactTriangles(encoder,
                                           *other_library_pipeline,
                                           geometry,
                                           0,
                                           3) == MetalDrawStatus::invalid_state);
        }
        if (other_library_geometry)
        {
            EXPECT(encodeArtifactTriangles(encoder,
                                           pipeline,
                                           *other_library_geometry,
                                           0,
                                           3) == MetalDrawStatus::invalid_state);
        }
    }

    for (id<MTLDevice> other_device in MTLCopyAllDevices())
    {
        if (other_device == device)
        {
            continue;
        }
        MetalProgramLibrary device_library((__bridge void*)other_device,
                                           metallib_path);
        EXPECT(device_library.valid());
        MetalRenderPipelineFamilyCache device_cache(device_library,
                                                     MetalProgramId::ui_font);
        EXPECT(device_cache.valid());
        const auto device_pipeline =
            device_cache.artifactPipeline({ BlendAttachmentDesc{} });
        EXPECT(device_pipeline.has_value());
        if (device_pipeline)
        {
            EXPECT(encodeArtifactTriangles(encoder,
                                           *device_pipeline,
                                           geometry,
                                           0,
                                           3) == MetalDrawStatus::invalid_state);
        }
    }
}

void renderOracle(id<MTLDevice> device,
                  id<MTLCommandQueue> queue,
                  const std::string& metallib_path,
                  MetalFrameContext& frames,
                  const MetalProgramLibrary& library,
                  const UiFontSemantics& semantics,
                  const UploadedResources& resources,
                  MetalRenderPipelineFamilyCache& pipeline_cache,
                  const MetalArtifactPipeline& pipeline,
                  const MetalArtifactGeometry& geometry)
{
    MetalPrivateTexture color;
    const auto target = createTarget(device, color);
    EXPECT(target.has_value());
    if (!target)
    {
        return;
    }

    id<MTLSamplerState> sampler = nil;
    {
        MTLSamplerDescriptor* descriptor = [[MTLSamplerDescriptor alloc] init];
        descriptor.minFilter = MTLSamplerMinMagFilterNearest;
        descriptor.magFilter = MTLSamplerMinMagFilterNearest;
        descriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
        descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sampler = [device newSamplerStateWithDescriptor:descriptor];
    }
    EXPECT(sampler != nil);
    if (sampler == nil)
    {
        return;
    }

    const auto lease = frames.tryBegin();
    EXPECT(lease.has_value());
    if (!lease)
    {
        return;
    }
    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    EXPECT(command_buffer != nil);
    if (command_buffer == nil)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }
    command_buffer.label = @"Firestorm ui_font artifact vertex/index oracle";

    MetalRenderPassDesc pass_descriptor;
    pass_descriptor.colors = {
        MetalColorAttachmentDesc{
            AttachmentLoadAction::clear,
            AttachmentStoreAction::store,
            MetalClearColor{ 0.0, 0.0, 0.0, 1.0 },
        },
    };
    pass_descriptor.label = "Firestorm ui_font exact 6x4 atlas";
    auto pass = beginRenderPass((__bridge void*)command_buffer,
                                *target,
                                pass_descriptor);
    EXPECT(pass.has_value());
    if (!pass)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    void* encoder_handle = pass->encoder();
    id<MTLRenderCommandEncoder> encoder =
        (__bridge id<MTLRenderCommandEncoder>)encoder_handle;
    EXPECT(encoder != nil);
    testDrawRejections(device,
                       metallib_path,
                       library,
                       resources,
                       semantics,
                       encoder_handle,
                       pipeline,
                       geometry);
    EXPECT(pipeline_cache.hitCount() == 2);
    EXPECT(pipeline_cache.missCount() == 1);
    EXPECT(pipeline_cache.entryCount() == 1);

    [encoder setViewport:MTLViewport{ 0.0,
                                     0.0,
                                     static_cast<double>(WIDTH),
                                     static_cast<double>(HEIGHT),
                                     0.0,
                                     1.0 }];
    [encoder setVertexBuffer:
                 (__bridge id<MTLBuffer>)resources.uniforms->nativeHandle()
                      offset:0
                     atIndex:semantics.uniformBuffer];
    [encoder setFragmentTexture:
                 (__bridge id<MTLTexture>)resources.whiteTexture->nativeHandle()
                        atIndex:semantics.textureIndex];
    [encoder setFragmentSamplerState:sampler atIndex:semantics.samplerIndex];

    const MetalIndexBufferBinding indices16{
        *resources.indices16,
        4 * sizeof(std::uint16_t),
        MetalIndexType::uint16,
    };
    const MetalIndexBufferBinding indices32{
        *resources.indices32,
        4 * sizeof(std::uint32_t),
        MetalIndexType::uint32,
    };

    [encoder setScissorRect:MTLScissorRect{ 0, 0, 2, 2 }];
    EXPECT(encodeArtifactTriangles(encoder_handle,
                                   pipeline,
                                   geometry,
                                   0,
                                   3) == MetalDrawStatus::encoded);
    [encoder setScissorRect:MTLScissorRect{ 2, 0, 2, 2 }];
    EXPECT(encodeArtifactIndexedTriangles(encoder_handle,
                                          pipeline,
                                          geometry,
                                          indices16,
                                          4,
                                          3) == MetalDrawStatus::encoded);
    [encoder setScissorRect:MTLScissorRect{ 4, 0, 2, 2 }];
    EXPECT(encodeArtifactIndexedTriangles(encoder_handle,
                                          pipeline,
                                          geometry,
                                          indices32,
                                          4,
                                          3) == MetalDrawStatus::encoded);
    [encoder setScissorRect:MTLScissorRect{ 0, 2, 2, 2 }];
    EXPECT(encodeArtifactIndexedTriangles(encoder_handle,
                                          pipeline,
                                          geometry,
                                          indices16,
                                          8,
                                          3) == MetalDrawStatus::encoded);
    [encoder setScissorRect:MTLScissorRect{ 2, 2, 2, 2 }];
    EXPECT(encodeArtifactTriangles(encoder_handle,
                                   pipeline,
                                   geometry,
                                   12,
                                   3) == MetalDrawStatus::encoded);
    EXPECT(pass->end());

    std::mutex publication_mutex;
    std::optional<MetalTextureReadback> publication;
    std::uint64_t publication_serial = 0;
    dispatch_semaphore_t published = dispatch_semaphore_create(0);
    MetalTransferBatch readback_batch((__bridge void*)device,
                                      frames,
                                      *lease,
                                      (__bridge void*)command_buffer,
                                      READBACK_BYTES);
    EXPECT(readback_batch.valid());
    const auto status = readback_batch.readbackTexture(
        color,
        MetalTextureRegion{ 0, 0, WIDTH, HEIGHT, 0, 0 },
        [&](std::uint64_t serial, MetalTextureReadback readback) {
            {
                std::lock_guard<std::mutex> lock(publication_mutex);
                publication_serial = serial;
                publication = std::move(readback);
            }
            dispatch_semaphore_signal(published);
        });
    EXPECT(status == MetalTransferStatus::encoded);
    if (status != MetalTransferStatus::encoded)
    {
        return;
    }
    auto completion = readback_batch.finish();
    EXPECT(completion.has_value());
    if (!completion)
    {
        return;
    }
    const auto render_serial = frames.submit(lease->token,
                                             (__bridge void*)command_buffer,
                                             std::move(*completion));
    EXPECT(render_serial.has_value());
    if (!render_serial)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }
    {
        std::lock_guard<std::mutex> lock(publication_mutex);
        EXPECT(!publication.has_value());
    }
    [command_buffer commit];
    requireSignal(published, command_buffer, "ui_font artifact render readback");
    EXPECT(command_buffer.status == MTLCommandBufferStatusCompleted);
    EXPECT(command_buffer.error == nil);

    std::lock_guard<std::mutex> lock(publication_mutex);
    EXPECT(publication.has_value());
    EXPECT(publication_serial == *render_serial);
    EXPECT(resources.submissionSerial !=
               std::numeric_limits<std::uint64_t>::max() &&
           *render_serial == resources.submissionSerial + 1);
    if (publication)
    {
        validateReadback(*publication);
    }
}

} // namespace

int main(int argc, const char* argv[])
{
    std::string metallib_path;
    if (!parseOptions(argc, argv, metallib_path))
    {
        return EXIT_FAILURE;
    }

    @autoreleasepool
    {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        EXPECT(device != nil);
        if (device == nil)
        {
            return EXIT_FAILURE;
        }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        EXPECT(queue != nil);
        if (queue == nil)
        {
            return EXIT_FAILURE;
        }

        MetalProgramLibrary library((__bridge void*)device, metallib_path);
        EXPECT(library.valid());
        if (!library.valid())
        {
            std::cerr << "FAIL load declared program library: "
                      << library.error() << '\n';
            return EXIT_FAILURE;
        }
        const auto semantics = inspectUiFont(library);
        if (!semantics)
        {
            return EXIT_FAILURE;
        }

        MetalProgramLibrary missing_library((__bridge void*)device,
                                            metallib_path + ".missing");
        EXPECT(!missing_library.valid());
        MetalRenderPipelineFamilyCache missing_cache(missing_library,
                                                      MetalProgramId::ui_font);
        EXPECT(!missing_cache.valid());
        EXPECT(!missing_cache.artifactPipeline({ BlendAttachmentDesc{} }).has_value());
        EXPECT(missing_cache.hitCount() == 0);
        EXPECT(missing_cache.missCount() == 0);
        EXPECT(missing_cache.entryCount() == 0);

        MetalRenderPipelineFamilyCache bad_id_cache(
            library,
            static_cast<MetalProgramId>(0));
        EXPECT(!bad_id_cache.valid());

        MetalRenderPipelineFamilyCache pipeline_cache(library,
                                                       MetalProgramId::ui_font);
        const auto pipeline = testPipelineCache(pipeline_cache);
        if (!pipeline)
        {
            return EXIT_FAILURE;
        }

        MetalFrameContext frames((__bridge void*)device, 8192);
        EXPECT(frames.valid());
        if (!frames.valid())
        {
            return EXIT_FAILURE;
        }
        const auto resources = uploadResources(device, queue, frames);
        if (!resources)
        {
            return EXIT_FAILURE;
        }
        const auto geometry = testGeometryValidation(library,
                                                     *resources,
                                                     *semantics);
        if (!geometry)
        {
            return EXIT_FAILURE;
        }

        renderOracle(device,
                     queue,
                     metallib_path,
                     frames,
                     library,
                     *semantics,
                     *resources,
                     pipeline_cache,
                     *pipeline,
                     *geometry);
    }

    if (gFailures != 0)
    {
        std::cerr << gFailures
                  << " Metal artifact vertex/index test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "PASS artifact-owned ui_font layout and U16/U32 draws"
              << " exact 6x4 BGRA atlas\n";
    return EXIT_SUCCESS;
}
