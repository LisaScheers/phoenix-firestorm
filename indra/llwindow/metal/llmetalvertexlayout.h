/**
 * @file llmetalvertexlayout.h
 * @brief Objective-C-free declared Metal vertex and program contracts.
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

#include <cstddef>
#include <cstdint>
#include <string_view>

namespace firestorm::metal
{

template<typename T>
struct MetalArrayView
{
    const T*    values = nullptr;
    std::size_t count  = 0;

    constexpr const T* begin() const noexcept { return values; }
    constexpr const T* end() const noexcept { return count == 0 ? values : values + count; }
    constexpr bool empty() const noexcept { return count == 0; }
    constexpr std::size_t size() const noexcept { return count; }
    constexpr const T& operator[](std::size_t index) const noexcept { return values[index]; }
};

template<typename T, std::size_t N>
constexpr MetalArrayView<T> metalArrayView(const T (&values)[N]) noexcept
{
    return { values, N };
}

template<typename T>
constexpr MetalArrayView<T> emptyMetalArrayView() noexcept
{
    return {};
}

enum class MetalVertexFormat : std::uint8_t
{
    float32,
    float32x2,
    float32x3,
    float32x4,
    int32,
    int32x2,
    int32x3,
    int32x4,
    uint32,
    uint32x2,
    uint32x3,
    uint32x4,
    uint8x4_normalized,
    uint16x4,
};

enum class MetalVertexStepFunction : std::uint8_t
{
    per_vertex,
    per_instance,
    constant,
};

struct MetalVertexAttributeDescriptor
{
    std::string_view  name;
    std::uint8_t      location;
    MetalVertexFormat format;
    std::uint16_t     offset;
    std::uint8_t      bufferIndex;
};

struct MetalVertexBufferLayoutDescriptor
{
    std::uint8_t            bufferIndex;
    std::uint16_t           stride;
    MetalVertexStepFunction stepFunction;
};

std::size_t metalVertexFormatSize(MetalVertexFormat format) noexcept;
bool validMetalVertexFormat(MetalVertexFormat format) noexcept;
bool validMetalVertexStepFunction(MetalVertexStepFunction step) noexcept;

} // namespace firestorm::metal
