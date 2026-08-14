/**
 * @file llmetalvertexlayout.cpp
 * @brief Ordinary-C++ helpers for declared Metal vertex layouts.
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

#include "llmetalvertexlayout.h"

namespace firestorm::metal
{

std::size_t metalVertexFormatSize(MetalVertexFormat format) noexcept
{
    switch (format)
    {
        case MetalVertexFormat::float32:
        case MetalVertexFormat::int32:
        case MetalVertexFormat::uint32:
        case MetalVertexFormat::uint8x4_normalized:
            return 4;
        case MetalVertexFormat::float32x2:
        case MetalVertexFormat::int32x2:
        case MetalVertexFormat::uint32x2:
        case MetalVertexFormat::uint16x4:
            return 8;
        case MetalVertexFormat::float32x3:
        case MetalVertexFormat::int32x3:
        case MetalVertexFormat::uint32x3:
            return 12;
        case MetalVertexFormat::float32x4:
        case MetalVertexFormat::int32x4:
        case MetalVertexFormat::uint32x4:
            return 16;
    }
    return 0;
}

bool validMetalVertexFormat(MetalVertexFormat format) noexcept
{
    return metalVertexFormatSize(format) != 0;
}

bool validMetalVertexStepFunction(MetalVertexStepFunction step) noexcept
{
    switch (step)
    {
        case MetalVertexStepFunction::per_vertex:
        case MetalVertexStepFunction::per_instance:
        case MetalVertexStepFunction::constant:
            return true;
    }
    return false;
}

} // namespace firestorm::metal
