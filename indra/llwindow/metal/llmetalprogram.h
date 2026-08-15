/**
 * @file llmetalprogram.h
 * @brief Immutable generated Metal program descriptors and library ownership.
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

#include "llmetalformat.h"
#include "llmetalframecontext.h"
#include "llmetalvertexlayout.h"

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

namespace firestorm::metal
{

enum class MetalProgramId : std::uint16_t;

enum class MetalResourceAccess : std::uint8_t
{
    read_only,
};

enum class MetalTextureType : std::uint8_t
{
    texture_1d,
    texture_1d_array,
    texture_2d,
    texture_2d_array,
    texture_2d_multisample,
    texture_2d_multisample_array,
    texture_3d,
    texture_cube,
    texture_cube_array,
    texture_buffer,
};

enum class MetalTextureDataType : std::uint8_t
{
    float32,
    float16,
    int32,
    uint32,
};

struct MetalBufferBindingDescriptor
{
    std::string_view    name;
    std::string_view    metalName;
    std::uint8_t        index;
    MetalResourceAccess access;
    std::uint32_t       size;
    std::uint16_t       alignment;
    std::string_view    layoutSha256;
};

struct MetalTextureBindingDescriptor
{
    std::string_view      name;
    std::string_view      metalName;
    std::uint8_t          index;
    MetalResourceAccess   access;
    MetalTextureType      type;
    MetalTextureDataType  dataType;
    std::uint16_t         arrayLength;
    bool                  depth;
};

struct MetalSamplerBindingDescriptor
{
    std::string_view name;
    std::string_view metalName;
    std::uint8_t     index;
};

struct MetalStageBindingDescriptors
{
    MetalArrayView<MetalBufferBindingDescriptor>  buffers;
    MetalArrayView<MetalTextureBindingDescriptor> textures;
    MetalArrayView<MetalSamplerBindingDescriptor> samplers;
};

struct MetalBooleanSettingDescriptor
{
    std::string_view name;
    bool             value;
};

struct MetalIntegerSettingDescriptor
{
    std::string_view name;
    std::int32_t     value;
};

inline constexpr std::uint16_t kSupportedMetalProgramArtifactSchema = 2;
inline constexpr std::uint16_t kSupportedMetalSourceManifestSchema = 4;

struct MetalProgramCatalogMetadata
{
    std::uint16_t    artifactSchema;
    std::uint16_t    sourceManifestSchema;
    std::uint16_t    programCount;
    std::uint16_t    familyCount;
    std::string_view libraryResource;
    std::string_view sourceManifestSha256;
    std::string_view baselineCommit;
    std::string_view metallibSha256;
    std::string_view reflectionSha256;
};

struct MetalProgramDescriptor
{
    MetalProgramId                              id;
    std::string_view                            name;
    std::string_view                            family;
    std::string_view                            sourceSymbol;
    std::optional<std::uint16_t>                sourceIndex;
    std::uint8_t                                shaderClass;
    MetalArrayView<MetalBooleanSettingDescriptor> booleanSettings;
    MetalArrayView<MetalIntegerSettingDescriptor> integerSettings;
    std::string_view                            vertexFunction;
    std::string_view                            fragmentFunction;
    MetalArrayView<PixelFormat>                 colorFormats;
    std::optional<PixelFormat>                  depthFormat;
    std::uint8_t                                sampleCount;
    MetalArrayView<MetalVertexAttributeDescriptor>    vertexAttributes;
    MetalArrayView<MetalVertexBufferLayoutDescriptor> vertexLayouts;
    MetalStageBindingDescriptors                vertexBindings;
    MetalStageBindingDescriptors                fragmentBindings;
    std::string_view                            vertexReflectionSha256;
    std::string_view                            fragmentReflectionSha256;
    std::string_view                            reflectionSha256;
};

/** Validate a complete immutable descriptor table without using Objective-C. */
bool validateMetalProgramCatalogMetadata(const MetalProgramCatalogMetadata& metadata,
                                         std::string* error = nullptr);
bool validateMetalProgramDescriptors(MetalArrayView<MetalProgramDescriptor> programs,
                                     std::string* error = nullptr);

/** Returns the generated catalog that owns the bundled library identity. */
const MetalProgramCatalogMetadata& metalProgramCatalog() noexcept;

using MetalProgramLibraryHandle = void*;

/**
 * Strongly owns one explicit offline metallib and all declared entry functions.
 *
 * The constructor performs no bundle lookup and never compiles source. The
 * native handle and descriptor pointers are borrowed and remain valid until
 * this object is destroyed. Generated enum values are lexical build ordinals;
 * callers persist or log the descriptor's string name instead.
 */
class MetalProgramLibrary final
{
public:
    MetalProgramLibrary(MetalDeviceHandle device, const std::string& metallib_path);
    ~MetalProgramLibrary();

    MetalProgramLibrary(const MetalProgramLibrary&)            = delete;
    MetalProgramLibrary& operator=(const MetalProgramLibrary&) = delete;
    MetalProgramLibrary(MetalProgramLibrary&&)                 = delete;
    MetalProgramLibrary& operator=(MetalProgramLibrary&&)      = delete;

    bool valid() const noexcept;
    const std::string& error() const noexcept;
    MetalProgramLibraryHandle nativeLibrary() const noexcept;
    const MetalProgramDescriptor* program(MetalProgramId id) const noexcept;
    const MetalProgramDescriptor* program(std::string_view id) const noexcept;
    const MetalProgramDescriptor* program(
        std::string_view source_symbol,
        std::optional<std::uint16_t> source_index,
        std::uint8_t shader_class) const noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> mImpl;
};

} // namespace firestorm::metal
