/**
 * @file program-library-test-objc.mm
 * @brief Exact catalog, ownership, and combined-library PSO validation.
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
#include "llmetalprogram.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>
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

using firestorm::metal::MetalArrayView;
using firestorm::metal::MetalProgramCatalogMetadata;
using firestorm::metal::MetalProgramDescriptor;
using firestorm::metal::MetalProgramId;
using firestorm::metal::MetalProgramLibrary;
using firestorm::metal::MetalResourceAccess;
using firestorm::metal::MetalTextureDataType;
using firestorm::metal::MetalTextureType;
using firestorm::metal::MetalVertexFormat;
using firestorm::metal::MetalVertexStepFunction;
using firestorm::metal::PixelFormat;
using firestorm::metal::declaredMetalProgramCatalog;
using firestorm::metal::declaredMetalPrograms;
using firestorm::metal::validateMetalProgramCatalogMetadata;
using firestorm::metal::validateMetalProgramDescriptors;

constexpr std::array<std::string_view, 13> EXPECTED_IDS{
    "avatar_skinning",
    "deferred_diffuse",
    "depth_copy",
    "fxaa",
    "indexed_material",
    "pbr_alpha",
    "pbr_opaque",
    "presentation_copy",
    "reflection_probe",
    "shadow_alpha_mask",
    "shadow_alpha_receiver",
    "terrain",
    "ui_font",
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
    return utf8 == nullptr ? std::string() : std::string(utf8);
}

NSString* toNSString(std::string_view value)
{
    return [[NSString alloc] initWithBytes:value.data()
                                   length:value.size()
                                 encoding:NSUTF8StringEncoding];
}

MTLPixelFormat nativePixelFormat(PixelFormat format)
{
    switch (format)
    {
        case PixelFormat::bgra8_unorm:
            return MTLPixelFormatBGRA8Unorm;
        case PixelFormat::rgba8_unorm:
            return MTLPixelFormatRGBA8Unorm;
        case PixelFormat::rgba8_unorm_srgb:
            return MTLPixelFormatRGBA8Unorm_sRGB;
        case PixelFormat::rgba16_unorm:
            return MTLPixelFormatRGBA16Unorm;
        case PixelFormat::rgba16_float:
            return MTLPixelFormatRGBA16Float;
        case PixelFormat::rg11b10_float:
            return MTLPixelFormatRG11B10Float;
        case PixelFormat::depth32_float:
            return MTLPixelFormatDepth32Float;
    }
    return MTLPixelFormatInvalid;
}

MTLVertexFormat nativeVertexFormat(MetalVertexFormat format)
{
    switch (format)
    {
        case MetalVertexFormat::float32:
            return MTLVertexFormatFloat;
        case MetalVertexFormat::float32x2:
            return MTLVertexFormatFloat2;
        case MetalVertexFormat::float32x3:
            return MTLVertexFormatFloat3;
        case MetalVertexFormat::float32x4:
            return MTLVertexFormatFloat4;
        case MetalVertexFormat::int32:
            return MTLVertexFormatInt;
        case MetalVertexFormat::int32x2:
            return MTLVertexFormatInt2;
        case MetalVertexFormat::int32x3:
            return MTLVertexFormatInt3;
        case MetalVertexFormat::int32x4:
            return MTLVertexFormatInt4;
        case MetalVertexFormat::uint32:
            return MTLVertexFormatUInt;
        case MetalVertexFormat::uint32x2:
            return MTLVertexFormatUInt2;
        case MetalVertexFormat::uint32x3:
            return MTLVertexFormatUInt3;
        case MetalVertexFormat::uint32x4:
            return MTLVertexFormatUInt4;
        case MetalVertexFormat::uint8x4_normalized:
            return MTLVertexFormatUChar4Normalized;
        case MetalVertexFormat::uint16x4:
            return MTLVertexFormatUShort4;
    }
    return MTLVertexFormatInvalid;
}

MTLVertexStepFunction nativeStepFunction(MetalVertexStepFunction step)
{
    switch (step)
    {
        case MetalVertexStepFunction::per_vertex:
            return MTLVertexStepFunctionPerVertex;
        case MetalVertexStepFunction::per_instance:
            return MTLVertexStepFunctionPerInstance;
        case MetalVertexStepFunction::constant:
            return MTLVertexStepFunctionConstant;
    }
    return MTLVertexStepFunctionPerVertex;
}

NSUInteger nativeStepRate(MetalVertexStepFunction step)
{
    return step == MetalVertexStepFunction::constant ? 0 : 1;
}

MTLVertexDescriptor* makeVertexDescriptor(const MetalProgramDescriptor& program)
{
    MTLVertexDescriptor* descriptor = [MTLVertexDescriptor vertexDescriptor];
    for (const auto& attribute : program.vertexAttributes)
    {
        descriptor.attributes[attribute.location].format =
            nativeVertexFormat(attribute.format);
        descriptor.attributes[attribute.location].offset = attribute.offset;
        descriptor.attributes[attribute.location].bufferIndex =
            attribute.bufferIndex;
    }
    for (const auto& layout : program.vertexLayouts)
    {
        descriptor.layouts[layout.bufferIndex].stride = layout.stride;
        descriptor.layouts[layout.bufferIndex].stepFunction =
            nativeStepFunction(layout.stepFunction);
        descriptor.layouts[layout.bufferIndex].stepRate =
            nativeStepRate(layout.stepFunction);
    }
    return descriptor;
}

bool createPipeline(id<MTLDevice> device,
                    id<MTLLibrary> library,
                    const MetalProgramDescriptor& program)
{
    NSString* vertex_name = toNSString(program.vertexFunction);
    NSString* fragment_name = toNSString(program.fragmentFunction);
    id<MTLFunction> vertex =
        vertex_name == nil ? nil : [library newFunctionWithName:vertex_name];
    id<MTLFunction> fragment =
        fragment_name == nil ? nil : [library newFunctionWithName:fragment_name];
    if (vertex == nil || fragment == nil)
    {
        return false;
    }

    MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label = toNSString(program.name);
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.rasterSampleCount = program.sampleCount;
    descriptor.vertexDescriptor = makeVertexDescriptor(program);
    for (std::size_t index = 0; index < program.colorFormats.size(); ++index)
    {
        descriptor.colorAttachments[index].pixelFormat =
            nativePixelFormat(program.colorFormats[index]);
    }
    if (program.depthFormat.has_value())
    {
        descriptor.depthAttachmentPixelFormat =
            nativePixelFormat(*program.depthFormat);
    }
    NSError* error = nil;
    id<MTLRenderPipelineState> pipeline =
        [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (pipeline == nil)
    {
        std::cerr << "FAIL create " << program.name << " PSO: "
                  << toString(error.localizedDescription) << '\n';
    }
    return pipeline != nil;
}

bool defaultUniformSlotsAre24(const MetalProgramDescriptor& program)
{
    for (const auto buffers : {
             program.vertexBindings.buffers,
             program.fragmentBindings.buffers,
         })
    {
        for (const auto& binding : buffers)
        {
            if (binding.name == "FirestormVertexUniforms" ||
                binding.name == "FirestormFragmentUniforms")
            {
                if (binding.index != 24)
                {
                    return false;
                }
            }
        }
    }
    return true;
}

bool hasVertexBuffer(const MetalProgramDescriptor& program, std::uint8_t index)
{
    for (const auto& layout : program.vertexLayouts)
    {
        if (layout.bufferIndex == index)
        {
            return true;
        }
    }
    return false;
}

void testPureValidation()
{
    EXPECT(nativeStepRate(MetalVertexStepFunction::per_vertex) == 1);
    EXPECT(nativeStepRate(MetalVertexStepFunction::per_instance) == 1);
    EXPECT(nativeStepRate(MetalVertexStepFunction::constant) == 0);

    std::string error;
    EXPECT(validateMetalProgramCatalogMetadata(declaredMetalProgramCatalog(), &error));
    EXPECT(error.empty());
    EXPECT(validateMetalProgramDescriptors(declaredMetalPrograms(), &error));
    EXPECT(error.empty());

    std::vector<MetalProgramDescriptor> changed(
        declaredMetalPrograms().begin(), declaredMetalPrograms().end());
    changed[0].id = static_cast<MetalProgramId>(0);
    EXPECT(!validateMetalProgramDescriptors({ changed.data(), changed.size() }, &error));

    changed.assign(declaredMetalPrograms().begin(), declaredMetalPrograms().end());
    changed[1].id = changed[0].id;
    EXPECT(!validateMetalProgramDescriptors({ changed.data(), changed.size() }, &error));

    changed.assign(declaredMetalPrograms().begin(), declaredMetalPrograms().end());
    changed[0].reflectionSha256 = "bad";
    EXPECT(!validateMetalProgramDescriptors({ changed.data(), changed.size() }, &error));

    changed.assign(declaredMetalPrograms().begin(), declaredMetalPrograms().end());
    std::vector<firestorm::metal::MetalVertexAttributeDescriptor> attributes(
        changed[0].vertexAttributes.begin(), changed[0].vertexAttributes.end());
    attributes[0].format = static_cast<MetalVertexFormat>(255);
    changed[0].vertexAttributes = { attributes.data(), attributes.size() };
    EXPECT(!validateMetalProgramDescriptors({ changed.data(), changed.size() }, &error));

    changed.assign(declaredMetalPrograms().begin(), declaredMetalPrograms().end());
    attributes.assign(
        changed[2].vertexAttributes.begin(), changed[2].vertexAttributes.end());
    std::vector<firestorm::metal::MetalVertexBufferLayoutDescriptor> layouts(
        changed[2].vertexLayouts.begin(), changed[2].vertexLayouts.end());
    const std::uint8_t original_buffer = layouts[0].bufferIndex;
    layouts[0].bufferIndex = 24;
    for (auto& attribute : attributes)
    {
        if (attribute.bufferIndex == original_buffer)
        {
            attribute.bufferIndex = 24;
        }
    }
    changed[2].vertexAttributes = { attributes.data(), attributes.size() };
    changed[2].vertexLayouts = { layouts.data(), layouts.size() };
    EXPECT(!validateMetalProgramDescriptors({ changed.data(), changed.size() }, &error));

    changed.assign(declaredMetalPrograms().begin(), declaredMetalPrograms().end());
    attributes.assign(
        changed[2].vertexAttributes.begin(), changed[2].vertexAttributes.end());
    attributes[0].location = 1;
    changed[2].vertexAttributes = { attributes.data(), attributes.size() };
    EXPECT(!validateMetalProgramDescriptors({ changed.data(), changed.size() }, &error));

    changed.assign(declaredMetalPrograms().begin(), declaredMetalPrograms().end());
    attributes.assign(
        changed[2].vertexAttributes.begin(), changed[2].vertexAttributes.end());
    attributes[0].offset = 2;
    changed[2].vertexAttributes = { attributes.data(), attributes.size() };
    EXPECT(!validateMetalProgramDescriptors({ changed.data(), changed.size() }, &error));

    changed.assign(declaredMetalPrograms().begin(), declaredMetalPrograms().end());
    layouts.assign(changed[2].vertexLayouts.begin(), changed[2].vertexLayouts.end());
    layouts[0].stride = 14;
    changed[2].vertexLayouts = { layouts.data(), layouts.size() };
    EXPECT(!validateMetalProgramDescriptors({ changed.data(), changed.size() }, &error));

    changed.assign(declaredMetalPrograms().begin(), declaredMetalPrograms().end());
    std::vector<firestorm::metal::MetalBufferBindingDescriptor> buffers(
        changed[0].vertexBindings.buffers.begin(),
        changed[0].vertexBindings.buffers.end());
    buffers[0].name = "../unsafe";
    changed[0].vertexBindings.buffers = { buffers.data(), buffers.size() };
    EXPECT(!validateMetalProgramDescriptors({ changed.data(), changed.size() }, &error));

    changed.assign(declaredMetalPrograms().begin(), declaredMetalPrograms().end());
    std::vector<firestorm::metal::MetalTextureBindingDescriptor> textures(
        changed[0].fragmentBindings.textures.begin(),
        changed[0].fragmentBindings.textures.end());
    std::vector<firestorm::metal::MetalSamplerBindingDescriptor> samplers(
        changed[0].fragmentBindings.samplers.begin(),
        changed[0].fragmentBindings.samplers.end());
    samplers[0].metalName = textures[0].metalName;
    changed[0].fragmentBindings.samplers = { samplers.data(), samplers.size() };
    EXPECT(!validateMetalProgramDescriptors({ changed.data(), changed.size() }, &error));

    changed.assign(declaredMetalPrograms().begin(), declaredMetalPrograms().end());
    buffers.assign(
        changed[0].vertexBindings.buffers.begin(),
        changed[0].vertexBindings.buffers.end());
    buffers[0].metalName = "../unsafe";
    changed[0].vertexBindings.buffers = { buffers.data(), buffers.size() };
    EXPECT(!validateMetalProgramDescriptors({ changed.data(), changed.size() }, &error));

    changed.assign(declaredMetalPrograms().begin(), declaredMetalPrograms().end());
    buffers.assign(
        changed[0].vertexBindings.buffers.begin(),
        changed[0].vertexBindings.buffers.end());
    buffers[0].index = changed[0].vertexLayouts[0].bufferIndex;
    changed[0].vertexBindings.buffers = { buffers.data(), buffers.size() };
    EXPECT(!validateMetalProgramDescriptors({ changed.data(), changed.size() }, &error));

    MetalProgramCatalogMetadata metadata = declaredMetalProgramCatalog();
    metadata.libraryResource = "../unsafe.metallib";
    EXPECT(!validateMetalProgramCatalogMetadata(metadata, &error));

    metadata = declaredMetalProgramCatalog();
    metadata.artifactSchema = static_cast<std::uint16_t>(
        firestorm::metal::kSupportedMetalProgramArtifactSchema + 1U);
    EXPECT(!validateMetalProgramCatalogMetadata(metadata, &error));

    metadata = declaredMetalProgramCatalog();
    metadata.sourceManifestSchema = static_cast<std::uint16_t>(
        firestorm::metal::kSupportedMetalSourceManifestSchema + 1U);
    EXPECT(!validateMetalProgramCatalogMetadata(metadata, &error));
}

void testExactCatalog(const MetalProgramLibrary& library)
{
    const auto programs = declaredMetalPrograms();
    const auto& catalog = declaredMetalProgramCatalog();
    EXPECT(programs.size() == EXPECTED_IDS.size());
    EXPECT(catalog.programCount == EXPECTED_IDS.size());
    EXPECT(catalog.familyCount == 10);
    EXPECT(catalog.artifactSchema ==
           firestorm::metal::kSupportedMetalProgramArtifactSchema);
    EXPECT(catalog.libraryResource == "firestorm-declared-programs.metallib");
    EXPECT(catalog.sourceManifestSchema ==
           firestorm::metal::kSupportedMetalSourceManifestSchema);
    EXPECT(catalog.sourceManifestSha256.size() == 64);
    EXPECT(catalog.baselineCommit.size() == 40);
    for (std::size_t index = 0; index < programs.size(); ++index)
    {
        EXPECT(programs[index].name == EXPECTED_IDS[index]);
        EXPECT(static_cast<std::uint16_t>(programs[index].id) == index + 1);
        EXPECT(library.program(programs[index].id) == &programs[index]);
        EXPECT(library.program(programs[index].name) == &programs[index]);
        EXPECT(defaultUniformSlotsAre24(programs[index]));
    }
    EXPECT(library.program(static_cast<MetalProgramId>(0)) == nullptr);
    EXPECT(library.program("missing_program") == nullptr);

    const MetalProgramDescriptor* ui = library.program("ui_font");
    EXPECT(ui != nullptr);
    if (ui != nullptr)
    {
        EXPECT(hasVertexBuffer(*ui, 16));
        EXPECT(hasVertexBuffer(*ui, 18));
        EXPECT(hasVertexBuffer(*ui, 20));
    }
    const MetalProgramDescriptor* indexed = library.program("indexed_material");
    EXPECT(indexed != nullptr);
    if (indexed != nullptr)
    {
        const auto* texture_index = indexed->vertexAttributes.end();
        for (const auto& attribute : indexed->vertexAttributes)
        {
            texture_index = attribute.name == "texture_index" ? &attribute : texture_index;
        }
        EXPECT(texture_index != indexed->vertexAttributes.end());
        if (texture_index != indexed->vertexAttributes.end())
        {
            EXPECT(texture_index->offset == 12);
            EXPECT(texture_index->bufferIndex == 16);
        }
    }
    const MetalProgramDescriptor* avatar = library.program("avatar_skinning");
    EXPECT(avatar != nullptr);
    if (avatar != nullptr)
    {
        EXPECT(hasVertexBuffer(*avatar, 22));
        EXPECT(hasVertexBuffer(*avatar, 23));
    }
    const MetalProgramDescriptor* deferred = library.program("deferred_diffuse");
    EXPECT(deferred != nullptr);
    if (deferred != nullptr)
    {
        EXPECT(deferred->colorFormats.size() == 3);
        EXPECT(deferred->colorFormats[0] == PixelFormat::rgba8_unorm);
        EXPECT(deferred->colorFormats[1] == PixelFormat::rgba8_unorm);
        EXPECT(deferred->colorFormats[2] == PixelFormat::rgba16_unorm);
        EXPECT(deferred->depthFormat == PixelFormat::depth32_float);
    }
    const MetalProgramDescriptor* presentation =
        library.program("presentation_copy");
    EXPECT(presentation != nullptr);
    if (presentation != nullptr)
    {
        EXPECT(presentation->family == "Depth write and copy");
        EXPECT(presentation->vertexFunction == "presentation_copy_vertex");
        EXPECT(presentation->fragmentFunction == "presentation_copy_fragment");
        EXPECT(presentation->colorFormats.size() == 1);
        if (presentation->colorFormats.size() == 1)
        {
            EXPECT(presentation->colorFormats[0] == PixelFormat::bgra8_unorm);
        }
        EXPECT(!presentation->depthFormat.has_value());
        EXPECT(presentation->sampleCount == 1);
        EXPECT(presentation->vertexAttributes.size() == 1);
        EXPECT(presentation->vertexLayouts.size() == 1);
        if (presentation->vertexAttributes.size() == 1)
        {
            const auto& position = presentation->vertexAttributes[0];
            EXPECT(position.name == "position");
            EXPECT(position.location == 0);
            EXPECT(position.format == MetalVertexFormat::float32x3);
            EXPECT(position.offset == 0);
            EXPECT(position.bufferIndex == 16);
        }
        if (presentation->vertexLayouts.size() == 1)
        {
            const auto& layout = presentation->vertexLayouts[0];
            EXPECT(layout.bufferIndex == 16);
            EXPECT(layout.stride == 16);
            EXPECT(layout.stepFunction == MetalVertexStepFunction::per_vertex);
        }
        EXPECT(presentation->vertexBindings.buffers.empty());
        EXPECT(presentation->vertexBindings.textures.empty());
        EXPECT(presentation->vertexBindings.samplers.empty());
        EXPECT(presentation->fragmentBindings.buffers.empty());
        EXPECT(presentation->fragmentBindings.textures.size() == 1);
        EXPECT(presentation->fragmentBindings.samplers.size() == 1);
        if (presentation->fragmentBindings.textures.size() == 1)
        {
            const auto& texture = presentation->fragmentBindings.textures[0];
            EXPECT(texture.name == "diffuseMap");
            EXPECT(texture.index == 0);
            EXPECT(texture.access == MetalResourceAccess::read_only);
            EXPECT(texture.type == MetalTextureType::texture_2d);
            EXPECT(texture.dataType == MetalTextureDataType::float32);
            EXPECT(texture.arrayLength == 1);
            EXPECT(!texture.depth);
        }
        if (presentation->fragmentBindings.samplers.size() == 1)
        {
            const auto& sampler = presentation->fragmentBindings.samplers[0];
            EXPECT(sampler.name == "diffuseMap");
            EXPECT(sampler.index == 0);
        }
    }
}

} // namespace

int main(int argc, const char* argv[])
{
    @autoreleasepool
    {
        std::string metallib_path;
        if (!parseOptions(argc, argv, metallib_path))
        {
            return EXIT_FAILURE;
        }
        testPureValidation();

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        EXPECT(device != nil);
        if (device == nil)
        {
            return EXIT_FAILURE;
        }
        MetalProgramLibrary invalid(nullptr, metallib_path);
        EXPECT(!invalid.valid());
        MetalProgramLibrary library((__bridge void*)device, metallib_path);
        if (!library.valid())
        {
            std::cerr << "FAIL load declared programs: " << library.error() << '\n';
            return EXIT_FAILURE;
        }
        EXPECT(library.nativeLibrary() != nullptr);
        testExactCatalog(library);

        id<MTLLibrary> native_library =
            (__bridge id<MTLLibrary>)library.nativeLibrary();
        for (const MetalProgramDescriptor& program : declaredMetalPrograms())
        {
            EXPECT(createPipeline(device, native_library, program));
        }
    }

    if (gFailures != 0)
    {
        std::cerr << gFailures << " declared program test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "declared program catalog/library: PASS\n";
    return EXIT_SUCCESS;
}
