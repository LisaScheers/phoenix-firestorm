/**
 * @file llmetalprogram.cpp
 * @brief Ordinary-C++ validation for generated Metal program contracts.
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

#include "llmetalprogram.h"

#include <array>
#include <limits>
#include <string>

namespace firestorm::metal
{
namespace
{

constexpr std::size_t MAX_VERTEX_ATTRIBUTES = 31;
constexpr std::size_t MAX_BUFFER_BINDINGS    = 31;
constexpr std::size_t MAX_TEXTURE_BINDINGS   = 128;
constexpr std::size_t MAX_SAMPLER_BINDINGS   = 16;

bool reject(std::string* error, const std::string& message)
{
    if (error != nullptr)
    {
        *error = message;
    }
    return false;
}

template<typename T>
bool validView(MetalArrayView<T> view) noexcept
{
    return view.count == 0 || view.values != nullptr;
}

bool safeIdentifier(std::string_view value) noexcept
{
    if (value.empty() || value.find('\0') != std::string_view::npos)
    {
        return false;
    }
    const auto ascii_alpha = [](char character) noexcept {
        return (character >= 'a' && character <= 'z') ||
               (character >= 'A' && character <= 'Z');
    };
    if (!ascii_alpha(value.front()) && value.front() != '_')
    {
        return false;
    }
    for (char character : value.substr(1))
    {
        const bool digit = character >= '0' && character <= '9';
        if (!ascii_alpha(character) && !digit && character != '_')
        {
            return false;
        }
    }
    return true;
}

int reservedAttributeLocation(std::string_view name) noexcept
{
    constexpr std::array<std::string_view, 14> names{
        "position",      "normal",   "texcoord0", "texcoord1", "texcoord2",
        "texcoord3",     "diffuse_color", "emissive", "tangent", "weight",
        "weight4",       "clothing", "joint",     "texture_index",
    };
    for (std::size_t index = 0; index < names.size(); ++index)
    {
        if (name == names[index])
        {
            return static_cast<int>(index);
        }
    }
    return -1;
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

bool safeDisplayText(std::string_view value) noexcept
{
    if (value.empty() || value.find('\0') != std::string_view::npos)
    {
        return false;
    }
    for (char character : value)
    {
        const auto byte = static_cast<unsigned char>(character);
        if (byte < 0x20U || byte > 0x7eU)
        {
            return false;
        }
    }
    return true;
}

bool sha256Text(std::string_view value) noexcept
{
    if (value.size() != 64)
    {
        return false;
    }
    for (char character : value)
    {
        if (!((character >= '0' && character <= '9') ||
              (character >= 'a' && character <= 'f')))
        {
            return false;
        }
    }
    return true;
}

bool gitObjectText(std::string_view value) noexcept
{
    if (value.size() != 40)
    {
        return false;
    }
    for (char character : value)
    {
        if (!((character >= '0' && character <= '9') ||
              (character >= 'a' && character <= 'f')))
        {
            return false;
        }
    }
    return true;
}

bool safeResourceBasename(std::string_view value) noexcept
{
    return safeDisplayText(value) && value.find('/') == std::string_view::npos &&
           value.find('\\') == std::string_view::npos &&
           value.find("..") == std::string_view::npos &&
           value == "firestorm-declared-programs.metallib";
}

bool validColorFormat(PixelFormat format) noexcept
{
    switch (format)
    {
        case PixelFormat::bgra8_unorm:
        case PixelFormat::rg11b10_float:
        case PixelFormat::rgba8_unorm:
        case PixelFormat::rgba8_unorm_srgb:
        case PixelFormat::rgba16_unorm:
        case PixelFormat::rgba16_float:
            return true;
        case PixelFormat::depth32_float:
            return false;
    }
    return false;
}

bool validAccess(MetalResourceAccess access) noexcept
{
    return access == MetalResourceAccess::read_only;
}

bool validTextureType(MetalTextureType type) noexcept
{
    switch (type)
    {
        case MetalTextureType::texture_1d:
        case MetalTextureType::texture_1d_array:
        case MetalTextureType::texture_2d:
        case MetalTextureType::texture_2d_array:
        case MetalTextureType::texture_2d_multisample:
        case MetalTextureType::texture_2d_multisample_array:
        case MetalTextureType::texture_3d:
        case MetalTextureType::texture_cube:
        case MetalTextureType::texture_cube_array:
        case MetalTextureType::texture_buffer:
            return true;
    }
    return false;
}

bool validTextureDataType(MetalTextureDataType type) noexcept
{
    switch (type)
    {
        case MetalTextureDataType::float32:
        case MetalTextureDataType::float16:
        case MetalTextureDataType::int32:
        case MetalTextureDataType::uint32:
            return true;
    }
    return false;
}

template<typename T>
bool namesUnique(MetalArrayView<T> values, std::string_view T::* field) noexcept
{
    for (std::size_t left = 0; left < values.size(); ++left)
    {
        for (std::size_t right = left + 1; right < values.size(); ++right)
        {
            if (values[left].*field == values[right].*field)
            {
                return false;
            }
        }
    }
    return true;
}

template<typename Left, typename Right>
bool namesDisjoint(MetalArrayView<Left> left_values,
                   std::string_view Left::* left_field,
                   MetalArrayView<Right> right_values,
                   std::string_view Right::* right_field) noexcept
{
    for (const Left& left : left_values)
    {
        for (const Right& right : right_values)
        {
            if (left.*left_field == right.*right_field)
            {
                return false;
            }
        }
    }
    return true;
}

bool validateBindings(const MetalStageBindingDescriptors& bindings,
                      std::string_view stage,
                      std::string* error)
{
    if (!validView(bindings.buffers) || !validView(bindings.textures) ||
        !validView(bindings.samplers))
    {
        return reject(error, std::string(stage) + " bindings have an invalid array view");
    }
    if (bindings.buffers.size() > MAX_BUFFER_BINDINGS ||
        bindings.textures.size() > MAX_TEXTURE_BINDINGS ||
        bindings.samplers.size() > MAX_SAMPLER_BINDINGS)
    {
        return reject(error, std::string(stage) + " binding count exceeds Metal limits");
    }

    std::array<bool, MAX_BUFFER_BINDINGS> buffer_slots{};
    std::array<bool, MAX_TEXTURE_BINDINGS> texture_slots{};
    std::array<bool, MAX_SAMPLER_BINDINGS> sampler_slots{};
    std::uint8_t previous_buffer = 0;
    bool first_buffer = true;
    for (const MetalBufferBindingDescriptor& binding : bindings.buffers)
    {
        const std::size_t index = binding.index;
        if (!safeIdentifier(binding.name) || !safeIdentifier(binding.metalName) ||
            !validAccess(binding.access) ||
            index >= buffer_slots.size() || buffer_slots[index] ||
            binding.size == 0 || binding.alignment == 0 ||
            (binding.alignment & static_cast<std::uint16_t>(binding.alignment - 1U)) != 0 ||
            binding.size % binding.alignment != 0 || !sha256Text(binding.layoutSha256) ||
            (!first_buffer && binding.index <= previous_buffer))
        {
            return reject(error, std::string(stage) + " has an invalid buffer binding");
        }
        buffer_slots[index] = true;
        previous_buffer = binding.index;
        first_buffer = false;
    }
    std::uint8_t previous_texture = 0;
    bool first_texture = true;
    for (const MetalTextureBindingDescriptor& binding : bindings.textures)
    {
        const std::size_t index = binding.index;
        if (!safeIdentifier(binding.name) || !safeIdentifier(binding.metalName) ||
            !validAccess(binding.access) ||
            !validTextureType(binding.type) || !validTextureDataType(binding.dataType) ||
            index >= texture_slots.size() || texture_slots[index] ||
            binding.arrayLength == 0 ||
            (binding.depth && binding.dataType != MetalTextureDataType::float32) ||
            (!first_texture && binding.index <= previous_texture))
        {
            return reject(error, std::string(stage) + " has an invalid texture binding");
        }
        texture_slots[index] = true;
        previous_texture = binding.index;
        first_texture = false;
    }
    std::uint8_t previous_sampler = 0;
    bool first_sampler = true;
    for (const MetalSamplerBindingDescriptor& binding : bindings.samplers)
    {
        const std::size_t index = binding.index;
        if (!safeIdentifier(binding.name) || !safeIdentifier(binding.metalName) ||
            index >= sampler_slots.size() || sampler_slots[index] ||
            (!first_sampler && binding.index <= previous_sampler))
        {
            return reject(error, std::string(stage) + " has an invalid sampler binding");
        }
        sampler_slots[index] = true;
        previous_sampler = binding.index;
        first_sampler = false;
    }
    if (!namesUnique(bindings.buffers, &MetalBufferBindingDescriptor::name) ||
        !namesUnique(bindings.textures, &MetalTextureBindingDescriptor::name) ||
        !namesUnique(bindings.samplers, &MetalSamplerBindingDescriptor::name))
    {
        return reject(error, std::string(stage) + " has duplicate resource names");
    }
    if (!namesUnique(bindings.buffers, &MetalBufferBindingDescriptor::metalName) ||
        !namesUnique(bindings.textures, &MetalTextureBindingDescriptor::metalName) ||
        !namesUnique(bindings.samplers, &MetalSamplerBindingDescriptor::metalName) ||
        !namesDisjoint(bindings.buffers,
                       &MetalBufferBindingDescriptor::metalName,
                       bindings.textures,
                       &MetalTextureBindingDescriptor::metalName) ||
        !namesDisjoint(bindings.buffers,
                       &MetalBufferBindingDescriptor::metalName,
                       bindings.samplers,
                       &MetalSamplerBindingDescriptor::metalName) ||
        !namesDisjoint(bindings.textures,
                       &MetalTextureBindingDescriptor::metalName,
                       bindings.samplers,
                       &MetalSamplerBindingDescriptor::metalName))
    {
        return reject(error, std::string(stage) + " has duplicate native Metal names");
    }
    if (bindings.textures.size() != bindings.samplers.size())
    {
        return reject(error, std::string(stage) + " texture and sampler bindings do not pair");
    }
    for (const MetalTextureBindingDescriptor& texture : bindings.textures)
    {
        bool matched = false;
        for (const MetalSamplerBindingDescriptor& sampler : bindings.samplers)
        {
            matched = matched ||
                      (sampler.index == texture.index && sampler.name == texture.name);
        }
        if (!matched)
        {
            return reject(error, std::string(stage) + " texture and sampler bindings do not pair");
        }
    }
    return true;
}

bool validateVertexContract(const MetalProgramDescriptor& program,
                            std::string* error)
{
    if (!validView(program.vertexAttributes) || !validView(program.vertexLayouts) ||
        program.vertexAttributes.size() > MAX_VERTEX_ATTRIBUTES ||
        program.vertexLayouts.size() > MAX_BUFFER_BINDINGS)
    {
        return reject(error, "invalid vertex descriptor array");
    }
    std::array<bool, MAX_BUFFER_BINDINGS> layouts{};
    std::array<bool, MAX_BUFFER_BINDINGS> used_layouts{};
    std::uint8_t previous_buffer = 0;
    bool first_layout = true;
    for (const MetalVertexBufferLayoutDescriptor& layout : program.vertexLayouts)
    {
        const std::size_t buffer = layout.bufferIndex;
        if (buffer >= layouts.size() || layouts[buffer] || layout.bufferIndex == 24 || layout.stride == 0 ||
            layout.stride > 2048 || !validMetalVertexStepFunction(layout.stepFunction) ||
            (!first_layout && layout.bufferIndex <= previous_buffer))
        {
            return reject(error, "invalid or noncanonical vertex buffer layout");
        }
        layouts[buffer] = true;
        previous_buffer = layout.bufferIndex;
        first_layout = false;
    }

    std::array<bool, MAX_VERTEX_ATTRIBUTES> locations{};
    std::uint8_t previous_location = 0;
    bool first_attribute = true;
    for (std::size_t left = 0; left < program.vertexAttributes.size(); ++left)
    {
        const MetalVertexAttributeDescriptor& attribute = program.vertexAttributes[left];
        const std::size_t location = attribute.location;
        const std::size_t buffer = attribute.bufferIndex;
        if (!safeIdentifier(attribute.name) ||
            reservedAttributeLocation(attribute.name) != static_cast<int>(attribute.location) ||
            location >= locations.size() ||
            locations[location] || buffer >= layouts.size() || !layouts[buffer] ||
            !validMetalVertexFormat(attribute.format) ||
            (!first_attribute && attribute.location <= previous_location))
        {
            return reject(error, "invalid or noncanonical vertex attribute");
        }
        const std::size_t size = metalVertexFormatSize(attribute.format);
        const auto layout = [&]() -> const MetalVertexBufferLayoutDescriptor* {
            for (const MetalVertexBufferLayoutDescriptor& candidate : program.vertexLayouts)
            {
                if (candidate.bufferIndex == attribute.bufferIndex)
                {
                    return &candidate;
                }
            }
            return nullptr;
        }();
        const std::size_t alignment = vertexFormatAlignment(attribute.format);
        if (layout == nullptr || alignment == 0 || attribute.offset > layout->stride ||
            size > static_cast<std::size_t>(layout->stride - attribute.offset) ||
            attribute.offset % alignment != 0 || layout->stride % alignment != 0)
        {
            return reject(error, "vertex attribute exceeds its stride");
        }
        for (std::size_t right = left + 1; right < program.vertexAttributes.size(); ++right)
        {
            if (attribute.name == program.vertexAttributes[right].name)
            {
                return reject(error, "duplicate vertex attribute name");
            }
        }
        locations[location] = true;
        used_layouts[buffer] = true;
        previous_location = attribute.location;
        first_attribute = false;
    }
    if (layouts != used_layouts)
    {
        return reject(error, "vertex descriptor has an unused buffer layout");
    }

    const MetalVertexAttributeDescriptor* position = nullptr;
    const MetalVertexAttributeDescriptor* texture_index = nullptr;
    for (const MetalVertexAttributeDescriptor& attribute : program.vertexAttributes)
    {
        position = attribute.name == "position" ? &attribute : position;
        texture_index = attribute.name == "texture_index" ? &attribute : texture_index;
    }
    if (texture_index != nullptr)
    {
        const MetalVertexBufferLayoutDescriptor* indexed_layout = nullptr;
        for (const MetalVertexBufferLayoutDescriptor& layout : program.vertexLayouts)
        {
            indexed_layout = layout.bufferIndex == texture_index->bufferIndex
                                 ? &layout
                                 : indexed_layout;
        }
        if (position == nullptr || indexed_layout == nullptr ||
            position->bufferIndex != texture_index->bufferIndex || position->offset != 0 ||
            texture_index->offset != 12 || texture_index->format != MetalVertexFormat::int32 ||
            indexed_layout->stride != 16)
        {
            return reject(error, "indexed position alias contract is invalid");
        }
    }
    return true;
}

} // namespace

bool validateMetalProgramCatalogMetadata(const MetalProgramCatalogMetadata& metadata,
                                         std::string* error)
{
    if (metadata.artifactSchema != kSupportedMetalProgramArtifactSchema ||
        metadata.sourceManifestSchema != kSupportedMetalSourceManifestSchema ||
        metadata.programCount == 0 || metadata.familyCount == 0 ||
        metadata.familyCount > metadata.programCount ||
        !safeResourceBasename(metadata.libraryResource) ||
        !sha256Text(metadata.sourceManifestSha256) ||
        !gitObjectText(metadata.baselineCommit) ||
        !sha256Text(metadata.metallibSha256) ||
        !sha256Text(metadata.reflectionSha256))
    {
        return reject(error, "program catalog metadata is invalid");
    }
    if (error != nullptr)
    {
        error->clear();
    }
    return true;
}

bool validateMetalProgramDescriptors(MetalArrayView<MetalProgramDescriptor> programs,
                                     std::string* error)
{
    if (!validView(programs) || programs.empty())
    {
        return reject(error, "program table must be nonempty and valid");
    }
    std::uint16_t expected_id = 1;
    std::string_view previous_name;
    for (const MetalProgramDescriptor& program : programs)
    {
        const auto numeric_id = static_cast<std::uint16_t>(program.id);
        if (numeric_id != expected_id ||
            !safeIdentifier(program.name) || !safeDisplayText(program.family) ||
            !safeIdentifier(program.vertexFunction) || !safeIdentifier(program.fragmentFunction) ||
            (!previous_name.empty() && program.name <= previous_name))
        {
            return reject(error, "program identity is invalid or noncanonical");
        }
        if (program.vertexFunction != std::string(program.name) + "_vertex" ||
            program.fragmentFunction != std::string(program.name) + "_fragment")
        {
            return reject(error, "program function name is not derived from its ID");
        }
        if (!validView(program.colorFormats) || program.colorFormats.size() > 4 ||
            program.sampleCount != 1 ||
            (program.colorFormats.empty() && !program.depthFormat.has_value()))
        {
            return reject(error, "program attachment contract is invalid");
        }
        for (PixelFormat format : program.colorFormats)
        {
            if (!validColorFormat(format))
            {
                return reject(error, "program has an invalid color format");
            }
        }
        if (program.depthFormat.has_value() &&
            *program.depthFormat != PixelFormat::depth32_float)
        {
            return reject(error, "program has an invalid depth format");
        }
        if (!validateVertexContract(program, error) ||
            !validateBindings(program.vertexBindings, "vertex", error) ||
            !validateBindings(program.fragmentBindings, "fragment", error))
        {
            return false;
        }
        for (const MetalBufferBindingDescriptor& binding : program.vertexBindings.buffers)
        {
            for (const MetalVertexBufferLayoutDescriptor& layout : program.vertexLayouts)
            {
                if (binding.index == layout.bufferIndex)
                {
                    return reject(error, "vertex stream collides with a shader buffer");
                }
            }
        }
        if (!sha256Text(program.vertexReflectionSha256) ||
            !sha256Text(program.fragmentReflectionSha256) ||
            !sha256Text(program.reflectionSha256))
        {
            return reject(error, "program reflection identity is invalid");
        }
        if (expected_id == std::numeric_limits<std::uint16_t>::max())
        {
            return reject(error, "program table exceeds the generated ID range");
        }
        ++expected_id;
        previous_name = program.name;
    }
    if (error != nullptr)
    {
        error->clear();
    }
    return true;
}

} // namespace firestorm::metal
