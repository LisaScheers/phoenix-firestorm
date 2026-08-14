/**
 * @file blend-pipeline-test-objc.mm
 * @brief Exact canonical blend-pipeline and one-attachment GPU validation.
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

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "llmetalpipeline.h"
#include "llmetalresource.h"
#include "llmetaltransfer.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <optional>
#include <string>
#include <utility>

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

using firestorm::metal::BlendAttachmentDesc;
using firestorm::metal::BlendAttachmentKey;
using firestorm::metal::BlendAttachmentKeyHash;
using firestorm::metal::BlendFactor;
using firestorm::metal::BlendOperation;
using firestorm::metal::ColorWriteMask;
using firestorm::metal::MetalFrameContext;
using firestorm::metal::MetalFrameLease;
using firestorm::metal::MetalPrivateTexture;
using firestorm::metal::MetalRenderPipelineFamilyCache;
using firestorm::metal::MetalRenderPipelineFamilyDesc;
using firestorm::metal::MetalRenderPipelineHandle;
using firestorm::metal::MetalTextureDescriptor;
using firestorm::metal::MetalTextureReadback;
using firestorm::metal::MetalTextureRegion;
using firestorm::metal::MetalTextureUsage;
using firestorm::metal::MetalTransferBatch;
using firestorm::metal::MetalTransferStatus;
using firestorm::metal::PixelFormat;
using firestorm::metal::createPrivateTexture;
using firestorm::metal::hasColorWrite;
using firestorm::metal::makeBlendAttachmentKey;

constexpr std::uint32_t WIDTH  = 9;
constexpr std::uint32_t HEIGHT = 1;
constexpr std::size_t ACTIVE_ROW_BYTES = 36;
constexpr const char* VERTEX_FUNCTION =
    "firestorm_blend_pipeline_vertex";
constexpr const char* FRAGMENT_FUNCTION =
    "firestorm_blend_pipeline_fragment";

struct alignas(16) FragmentColorBytes
{
    std::uint32_t red;
    std::uint32_t green;
    std::uint32_t blue;
    std::uint32_t alpha;
};

static_assert(sizeof(FragmentColorBytes) == 16,
              "Fragment bytes must match the Metal uint4 constant");

constexpr std::array<FragmentColorBytes, WIDTH> DESTINATIONS{
    FragmentColorBytes{ 0, 255, 255, 255 },
    FragmentColorBytes{ 23, 137, 211, 96 },
    FragmentColorBytes{ 86, 154, 32, 211 },
    FragmentColorBytes{ 0, 255, 0, 96 },
    FragmentColorBytes{ 128, 64, 32, 160 },
    FragmentColorBytes{ 128, 64, 32, 160 },
    FragmentColorBytes{ 128, 64, 32, 160 },
    FragmentColorBytes{ 128, 64, 32, 160 },
    FragmentColorBytes{ 128, 64, 32, 160 },
};

constexpr std::array<FragmentColorBytes, WIDTH> SOURCES{
    FragmentColorBytes{ 255, 0, 255, 64 },
    FragmentColorBytes{ 255, 0, 255, 64 },
    FragmentColorBytes{ 255, 0, 255, 193 },
    FragmentColorBytes{ 255, 0, 255, 193 },
    FragmentColorBytes{ 32, 96, 160, 64 },
    FragmentColorBytes{ 32, 96, 160, 64 },
    FragmentColorBytes{ 32, 96, 160, 64 },
    FragmentColorBytes{ 32, 96, 160, 64 },
    FragmentColorBytes{ 32, 96, 160, 64 },
};

constexpr std::array<std::uint8_t, ACTIVE_ROW_BYTES> EXPECTED_PIXELS{
    64, 191, 255, 191,
    255, 137, 211, 160,
    143, 61, 60, 193,
    96, 159, 96, 96,
    160, 160, 192, 0,
    0, 32, 128, 96,
    96, 0, 0, 64,
    32, 64, 32, 160,
    128, 96, 160, 224,
};

constexpr ColorWriteMask RGB_WRITE_MASK =
    ColorWriteMask::red | ColorWriteMask::green | ColorWriteMask::blue;
constexpr PixelFormat TEST_COLOR_FORMAT = PixelFormat::rgba8_unorm;

std::string toString(NSString* value)
{
    if (value == nil)
    {
        return {};
    }

    const char* utf8 = value.UTF8String;
    return utf8 == nullptr ? std::string() : std::string(utf8);
}

std::string commandError(id<MTLCommandBuffer> command_buffer)
{
    if (command_buffer == nil || command_buffer.error == nil)
    {
        return {};
    }
    return toString(command_buffer.error.localizedDescription);
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
              << " status="
              << static_cast<unsigned long>(command_buffer.status)
              << " error=\"" << commandError(command_buffer) << "\"\n";
    std::_Exit(EXIT_FAILURE);
}

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

id<MTLLibrary> loadLibrary(id<MTLDevice> device, const std::string& path)
{
    NSString* native_path = [[NSString alloc] initWithBytes:path.data()
                                                      length:path.size()
                                                    encoding:NSUTF8StringEncoding];
    EXPECT(native_path != nil);
    if (native_path == nil)
    {
        return nil;
    }

    NSError* error = nil;
    id<MTLLibrary> library =
        [device newLibraryWithURL:[NSURL fileURLWithPath:native_path]
                            error:&error];
    if (library == nil)
    {
        std::cerr << "FAIL load blend/pipeline metallib: "
                  << toString(error.localizedDescription) << '\n';
        ++gFailures;
    }
    return library;
}

MetalRenderPipelineFamilyDesc familyDescriptor()
{
    MetalRenderPipelineFamilyDesc descriptor;
    descriptor.vertexFunction = VERTEX_FUNCTION;
    descriptor.fragmentFunction = FRAGMENT_FUNCTION;
    descriptor.colorFormat = PixelFormat::rgba8_unorm;
    return descriptor;
}

void expectEquivalent(const BlendAttachmentDesc& lhs,
                      const BlendAttachmentDesc& rhs,
                      PixelFormat color_format = TEST_COLOR_FORMAT)
{
    const auto lhs_key = makeBlendAttachmentKey(lhs, color_format);
    const auto rhs_key = makeBlendAttachmentKey(rhs, color_format);
    EXPECT(lhs_key.has_value());
    EXPECT(rhs_key.has_value());
    EXPECT(lhs_key == rhs_key);
    if (lhs_key && rhs_key)
    {
        EXPECT(BlendAttachmentKeyHash{}(*lhs_key) ==
               BlendAttachmentKeyHash{}(*rhs_key));
    }
}

void testKeyContract()
{
    const BlendAttachmentDesc default_descriptor;
    const auto default_key = makeBlendAttachmentKey(default_descriptor,
                                                     TEST_COLOR_FORMAT);
    EXPECT(default_key.has_value());
    if (default_key)
    {
        EXPECT(!default_key->blendingEnabled);
        EXPECT(default_key->rgbOperation == BlendOperation::add);
        EXPECT(default_key->sourceRGBFactor == BlendFactor::one);
        EXPECT(default_key->destinationRGBFactor == BlendFactor::zero);
        EXPECT(default_key->alphaOperation == BlendOperation::add);
        EXPECT(default_key->sourceAlphaFactor == BlendFactor::one);
        EXPECT(default_key->destinationAlphaFactor == BlendFactor::zero);
        EXPECT(default_key->writeMask == ColorWriteMask::all);
    }

    EXPECT(hasColorWrite(ColorWriteMask::all, ColorWriteMask::red));
    EXPECT(hasColorWrite(ColorWriteMask::all, ColorWriteMask::green));
    EXPECT(hasColorWrite(ColorWriteMask::all, ColorWriteMask::blue));
    EXPECT(hasColorWrite(ColorWriteMask::all, ColorWriteMask::alpha));
    EXPECT(!hasColorWrite(ColorWriteMask::none, ColorWriteMask::all));

    BlendAttachmentDesc ignored;
    ignored.rgbOperation = BlendOperation::max;
    ignored.sourceRGBFactor = BlendFactor::destination_alpha;
    ignored.destinationRGBFactor = BlendFactor::source_color;
    ignored.alphaOperation = BlendOperation::min;
    ignored.sourceAlphaFactor = BlendFactor::destination_color;
    ignored.destinationAlphaFactor = BlendFactor::one_minus_source_color;
    expectEquivalent(default_descriptor, ignored);

    BlendAttachmentDesc no_write = ignored;
    no_write.blendingEnabled = true;
    no_write.writeMask = ColorWriteMask::none;
    BlendAttachmentDesc no_write_equivalent;
    no_write_equivalent.writeMask = ColorWriteMask::none;
    expectEquivalent(no_write, no_write_equivalent);

    BlendAttachmentDesc alpha_only;
    alpha_only.blendingEnabled = true;
    alpha_only.writeMask = ColorWriteMask::alpha;
    BlendAttachmentDesc alpha_only_equivalent = alpha_only;
    alpha_only_equivalent.rgbOperation = BlendOperation::reverse_subtract;
    alpha_only_equivalent.sourceRGBFactor = BlendFactor::source_alpha;
    alpha_only_equivalent.destinationRGBFactor =
        BlendFactor::one_minus_destination_color;
    expectEquivalent(alpha_only, alpha_only_equivalent);

    BlendAttachmentDesc rgb_only;
    rgb_only.blendingEnabled = true;
    rgb_only.writeMask = RGB_WRITE_MASK;
    BlendAttachmentDesc rgb_only_equivalent = rgb_only;
    rgb_only_equivalent.alphaOperation = BlendOperation::subtract;
    rgb_only_equivalent.sourceAlphaFactor = BlendFactor::destination_alpha;
    rgb_only_equivalent.destinationAlphaFactor =
        BlendFactor::one_minus_source_alpha;
    expectEquivalent(rgb_only, rgb_only_equivalent);

    BlendAttachmentDesc minimum;
    minimum.blendingEnabled = true;
    minimum.rgbOperation = BlendOperation::min;
    minimum.sourceRGBFactor = BlendFactor::zero;
    minimum.destinationRGBFactor = BlendFactor::destination_alpha;
    BlendAttachmentDesc minimum_equivalent = minimum;
    minimum_equivalent.sourceRGBFactor = BlendFactor::source_color;
    minimum_equivalent.destinationRGBFactor = BlendFactor::one_minus_source_color;
    expectEquivalent(minimum, minimum_equivalent);
    const auto minimum_key = makeBlendAttachmentKey(minimum,
                                                     TEST_COLOR_FORMAT);
    EXPECT(minimum_key.has_value());
    if (minimum_key)
    {
        EXPECT(minimum_key->sourceRGBFactor == BlendFactor::one);
        EXPECT(minimum_key->destinationRGBFactor == BlendFactor::one);
    }

    BlendAttachmentDesc maximum;
    maximum.blendingEnabled = true;
    maximum.alphaOperation = BlendOperation::max;
    maximum.sourceAlphaFactor = BlendFactor::zero;
    maximum.destinationAlphaFactor = BlendFactor::destination_color;
    BlendAttachmentDesc maximum_equivalent = maximum;
    maximum_equivalent.sourceAlphaFactor = BlendFactor::source_color;
    maximum_equivalent.destinationAlphaFactor = BlendFactor::one_minus_source_color;
    expectEquivalent(maximum, maximum_equivalent);

    BlendAttachmentDesc aliases;
    aliases.blendingEnabled = true;
    aliases.sourceAlphaFactor = BlendFactor::source_color;
    aliases.destinationAlphaFactor = BlendFactor::one_minus_destination_color;
    BlendAttachmentDesc aliases_equivalent = aliases;
    aliases_equivalent.sourceAlphaFactor = BlendFactor::source_alpha;
    aliases_equivalent.destinationAlphaFactor =
        BlendFactor::one_minus_destination_alpha;
    expectEquivalent(aliases, aliases_equivalent);

    BlendAttachmentDesc live = aliases_equivalent;
    BlendAttachmentDesc distinct = live;
    distinct.sourceRGBFactor = BlendFactor::source_alpha;
    EXPECT(makeBlendAttachmentKey(live, TEST_COLOR_FORMAT) !=
           makeBlendAttachmentKey(distinct, TEST_COLOR_FORMAT));
    distinct = live;
    distinct.writeMask = ColorWriteMask::red;
    EXPECT(makeBlendAttachmentKey(live, TEST_COLOR_FORMAT) !=
           makeBlendAttachmentKey(distinct, TEST_COLOR_FORMAT));

    BlendAttachmentDesc invalid;
    invalid.writeMask = ColorWriteMask::none;
    invalid.rgbOperation = static_cast<BlendOperation>(255);
    EXPECT(!makeBlendAttachmentKey(invalid, TEST_COLOR_FORMAT).has_value());
    invalid = BlendAttachmentDesc{};
    invalid.writeMask = ColorWriteMask::none;
    invalid.alphaOperation = static_cast<BlendOperation>(255);
    EXPECT(!makeBlendAttachmentKey(invalid, TEST_COLOR_FORMAT).has_value());
    invalid = BlendAttachmentDesc{};
    invalid.sourceRGBFactor = static_cast<BlendFactor>(255);
    EXPECT(!makeBlendAttachmentKey(invalid, TEST_COLOR_FORMAT).has_value());
    invalid = BlendAttachmentDesc{};
    invalid.destinationRGBFactor = static_cast<BlendFactor>(255);
    EXPECT(!makeBlendAttachmentKey(invalid, TEST_COLOR_FORMAT).has_value());
    invalid = BlendAttachmentDesc{};
    invalid.sourceAlphaFactor = static_cast<BlendFactor>(255);
    EXPECT(!makeBlendAttachmentKey(invalid, TEST_COLOR_FORMAT).has_value());
    invalid = BlendAttachmentDesc{};
    invalid.destinationAlphaFactor = static_cast<BlendFactor>(255);
    EXPECT(!makeBlendAttachmentKey(invalid, TEST_COLOR_FORMAT).has_value());
    invalid = BlendAttachmentDesc{};
    invalid.writeMask = static_cast<ColorWriteMask>(16);
    EXPECT(!makeBlendAttachmentKey(invalid, TEST_COLOR_FORMAT).has_value());

    BlendAttachmentDesc alpha_less_all;
    alpha_less_all.blendingEnabled = true;
    alpha_less_all.sourceRGBFactor = BlendFactor::destination_alpha;
    alpha_less_all.destinationRGBFactor =
        BlendFactor::one_minus_destination_alpha;
    alpha_less_all.alphaOperation = BlendOperation::subtract;
    alpha_less_all.sourceAlphaFactor = BlendFactor::destination_color;
    alpha_less_all.destinationAlphaFactor =
        BlendFactor::one_minus_source_color;
    BlendAttachmentDesc alpha_less_rgb = alpha_less_all;
    alpha_less_rgb.sourceRGBFactor = BlendFactor::one;
    alpha_less_rgb.destinationRGBFactor = BlendFactor::zero;
    alpha_less_rgb.alphaOperation = BlendOperation::max;
    alpha_less_rgb.sourceAlphaFactor = BlendFactor::zero;
    alpha_less_rgb.destinationAlphaFactor = BlendFactor::one;
    alpha_less_rgb.writeMask = RGB_WRITE_MASK;
    expectEquivalent(alpha_less_all,
                     alpha_less_rgb,
                     PixelFormat::rg11b10_float);
    BlendAttachmentDesc alpha_bearing_factor_state = alpha_less_all;
    alpha_bearing_factor_state.sourceRGBFactor = BlendFactor::one;
    alpha_bearing_factor_state.destinationRGBFactor = BlendFactor::zero;
    EXPECT(makeBlendAttachmentKey(alpha_less_all, TEST_COLOR_FORMAT) !=
           makeBlendAttachmentKey(alpha_bearing_factor_state,
                                  TEST_COLOR_FORMAT));
    BlendAttachmentDesc alpha_bearing_rgb_write = alpha_less_all;
    alpha_bearing_rgb_write.writeMask = RGB_WRITE_MASK;
    EXPECT(makeBlendAttachmentKey(alpha_less_all, TEST_COLOR_FORMAT) !=
           makeBlendAttachmentKey(alpha_bearing_rgb_write,
                                  TEST_COLOR_FORMAT));
    const auto alpha_less_key = makeBlendAttachmentKey(
        alpha_less_all,
        PixelFormat::rg11b10_float);
    EXPECT(alpha_less_key.has_value());
    if (alpha_less_key)
    {
        EXPECT(alpha_less_key->writeMask == RGB_WRITE_MASK);
        EXPECT(alpha_less_key->sourceRGBFactor == BlendFactor::one);
        EXPECT(alpha_less_key->destinationRGBFactor == BlendFactor::zero);
        EXPECT(alpha_less_key->alphaOperation == BlendOperation::add);
        EXPECT(alpha_less_key->sourceAlphaFactor == BlendFactor::one);
        EXPECT(alpha_less_key->destinationAlphaFactor == BlendFactor::zero);
    }
    BlendAttachmentDesc alpha_only_no_storage;
    alpha_only_no_storage.blendingEnabled = true;
    alpha_only_no_storage.rgbOperation = BlendOperation::subtract;
    alpha_only_no_storage.sourceRGBFactor = BlendFactor::destination_alpha;
    alpha_only_no_storage.writeMask = ColorWriteMask::alpha;
    BlendAttachmentDesc no_write_no_storage;
    no_write_no_storage.writeMask = ColorWriteMask::none;
    expectEquivalent(alpha_only_no_storage,
                     no_write_no_storage,
                     PixelFormat::rg11b10_float);

    BlendAttachmentDesc hidden_invalid;
    hidden_invalid.writeMask = ColorWriteMask::alpha;
    hidden_invalid.alphaOperation = static_cast<BlendOperation>(255);
    EXPECT(!makeBlendAttachmentKey(hidden_invalid,
                                   PixelFormat::rg11b10_float).has_value());
    hidden_invalid = BlendAttachmentDesc{};
    hidden_invalid.writeMask =
        ColorWriteMask::alpha | static_cast<ColorWriteMask>(16);
    EXPECT(!makeBlendAttachmentKey(hidden_invalid,
                                   PixelFormat::rg11b10_float).has_value());
    EXPECT(!makeBlendAttachmentKey(default_descriptor,
                                   PixelFormat::depth32_float).has_value());
    EXPECT(!makeBlendAttachmentKey(default_descriptor,
                                   static_cast<PixelFormat>(255)).has_value());
}

void expectInvalidFamily(MetalRenderPipelineFamilyCache& cache)
{
    EXPECT(!cache.valid());
    EXPECT(!cache.pipeline(BlendAttachmentDesc{}).has_value());
    EXPECT(cache.hitCount() == 0);
    EXPECT(cache.missCount() == 0);
    EXPECT(cache.entryCount() == 0);
}

void testInvalidFamilies(id<MTLDevice> device, id<MTLLibrary> library)
{
    const auto valid_descriptor = familyDescriptor();

    MetalRenderPipelineFamilyCache null_cache(nullptr, nullptr,
                                                valid_descriptor);
    expectInvalidFamily(null_cache);

    NSObject* wrong_type = [[NSObject alloc] init];
    MetalRenderPipelineFamilyCache wrong_device((__bridge void*)wrong_type,
                                                  (__bridge void*)library,
                                                  valid_descriptor);
    expectInvalidFamily(wrong_device);
    MetalRenderPipelineFamilyCache wrong_library((__bridge void*)device,
                                                   (__bridge void*)wrong_type,
                                                   valid_descriptor);
    expectInvalidFamily(wrong_library);

    auto wrong_vertex_stage = valid_descriptor;
    wrong_vertex_stage.vertexFunction = FRAGMENT_FUNCTION;
    MetalRenderPipelineFamilyCache vertex_stage_cache(
        (__bridge void*)device, (__bridge void*)library, wrong_vertex_stage);
    expectInvalidFamily(vertex_stage_cache);

    auto wrong_fragment_stage = valid_descriptor;
    wrong_fragment_stage.fragmentFunction = VERTEX_FUNCTION;
    MetalRenderPipelineFamilyCache fragment_stage_cache(
        (__bridge void*)device, (__bridge void*)library, wrong_fragment_stage);
    expectInvalidFamily(fragment_stage_cache);

    auto missing_function = valid_descriptor;
    missing_function.vertexFunction = "firestorm_missing_vertex";
    MetalRenderPipelineFamilyCache missing_function_cache(
        (__bridge void*)device, (__bridge void*)library, missing_function);
    expectInvalidFamily(missing_function_cache);

    auto invalid_utf8 = valid_descriptor;
    invalid_utf8.fragmentFunction = std::string("\xff", 1);
    MetalRenderPipelineFamilyCache invalid_utf8_cache(
        (__bridge void*)device, (__bridge void*)library, invalid_utf8);
    expectInvalidFamily(invalid_utf8_cache);

    auto depth_as_color = valid_descriptor;
    depth_as_color.colorFormat = PixelFormat::depth32_float;
    MetalRenderPipelineFamilyCache depth_as_color_cache(
        (__bridge void*)device, (__bridge void*)library, depth_as_color);
    expectInvalidFamily(depth_as_color_cache);

    auto color_as_depth = valid_descriptor;
    color_as_depth.depthFormat = PixelFormat::rgba8_unorm;
    MetalRenderPipelineFamilyCache color_as_depth_cache(
        (__bridge void*)device, (__bridge void*)library, color_as_depth);
    expectInvalidFamily(color_as_depth_cache);

    auto invalid_color = valid_descriptor;
    invalid_color.colorFormat = static_cast<PixelFormat>(255);
    MetalRenderPipelineFamilyCache invalid_color_cache(
        (__bridge void*)device, (__bridge void*)library, invalid_color);
    expectInvalidFamily(invalid_color_cache);

    auto depth_descriptor = valid_descriptor;
    depth_descriptor.depthFormat = PixelFormat::depth32_float;
    MetalRenderPipelineFamilyCache depth_family(
        (__bridge void*)device, (__bridge void*)library, depth_descriptor);
    EXPECT(depth_family.valid());
    EXPECT(depth_family.pipeline(BlendAttachmentDesc{}).has_value());
    EXPECT(depth_family.missCount() == 1);
    EXPECT(depth_family.entryCount() == 1);

    auto alpha_less_descriptor = valid_descriptor;
    alpha_less_descriptor.colorFormat = PixelFormat::rg11b10_float;
    MetalRenderPipelineFamilyCache alpha_less_family(
        (__bridge void*)device,
        (__bridge void*)library,
        alpha_less_descriptor);
    EXPECT(alpha_less_family.valid());
    BlendAttachmentDesc alpha_less_all;
    alpha_less_all.blendingEnabled = true;
    alpha_less_all.sourceRGBFactor = BlendFactor::destination_alpha;
    alpha_less_all.destinationRGBFactor =
        BlendFactor::one_minus_destination_alpha;
    alpha_less_all.alphaOperation = BlendOperation::subtract;
    alpha_less_all.sourceAlphaFactor = BlendFactor::destination_color;
    BlendAttachmentDesc alpha_less_rgb = alpha_less_all;
    alpha_less_rgb.sourceRGBFactor = BlendFactor::one;
    alpha_less_rgb.destinationRGBFactor = BlendFactor::zero;
    alpha_less_rgb.alphaOperation = BlendOperation::max;
    alpha_less_rgb.sourceAlphaFactor = BlendFactor::zero;
    alpha_less_rgb.writeMask = RGB_WRITE_MASK;
    const auto alpha_less_all_pipeline =
        alpha_less_family.pipeline(alpha_less_all);
    const auto alpha_less_rgb_pipeline =
        alpha_less_family.pipeline(alpha_less_rgb);
    EXPECT(alpha_less_all_pipeline.has_value());
    EXPECT(alpha_less_rgb_pipeline == alpha_less_all_pipeline);

    BlendAttachmentDesc alpha_only_no_storage;
    alpha_only_no_storage.blendingEnabled = true;
    alpha_only_no_storage.rgbOperation = BlendOperation::subtract;
    alpha_only_no_storage.writeMask = ColorWriteMask::alpha;
    BlendAttachmentDesc no_write_no_storage;
    no_write_no_storage.writeMask = ColorWriteMask::none;
    const auto alpha_only_pipeline =
        alpha_less_family.pipeline(alpha_only_no_storage);
    const auto no_write_pipeline =
        alpha_less_family.pipeline(no_write_no_storage);
    EXPECT(alpha_only_pipeline.has_value());
    EXPECT(no_write_pipeline == alpha_only_pipeline);
    BlendAttachmentDesc hidden_invalid;
    hidden_invalid.writeMask =
        ColorWriteMask::alpha | static_cast<ColorWriteMask>(16);
    EXPECT(!alpha_less_family.pipeline(hidden_invalid).has_value());
    EXPECT(alpha_less_family.hitCount() == 2);
    EXPECT(alpha_less_family.missCount() == 2);
    EXPECT(alpha_less_family.entryCount() == 2);

    for (id<MTLDevice> other_device in MTLCopyAllDevices())
    {
        if (other_device == device)
        {
            continue;
        }
        MetalRenderPipelineFamilyCache mismatched_device(
            (__bridge void*)other_device,
            (__bridge void*)library,
            valid_descriptor);
        expectInvalidFamily(mismatched_device);
    }
}

std::array<BlendAttachmentDesc, WIDTH> cellDescriptors()
{
    std::array<BlendAttachmentDesc, WIDTH> descriptors;
    for (auto& descriptor : descriptors)
    {
        descriptor.blendingEnabled = true;
    }

    descriptors[0].sourceRGBFactor = BlendFactor::source_alpha;
    descriptors[0].destinationRGBFactor =
        BlendFactor::one_minus_source_alpha;
    descriptors[0].sourceAlphaFactor = BlendFactor::zero;
    descriptors[0].destinationAlphaFactor =
        BlendFactor::one_minus_source_alpha;

    descriptors[1].sourceRGBFactor = BlendFactor::source_color;
    descriptors[1].destinationRGBFactor =
        BlendFactor::one_minus_source_color;
    descriptors[1].sourceAlphaFactor = BlendFactor::one;
    descriptors[1].destinationAlphaFactor = BlendFactor::one;
    descriptors[1].writeMask =
        ColorWriteMask::red | ColorWriteMask::green | ColorWriteMask::alpha;

    descriptors[2].sourceRGBFactor = BlendFactor::destination_color;
    descriptors[2].destinationRGBFactor =
        BlendFactor::one_minus_destination_color;
    descriptors[2].sourceAlphaFactor = BlendFactor::one;
    descriptors[2].destinationAlphaFactor = BlendFactor::zero;

    descriptors[3].sourceRGBFactor = BlendFactor::destination_alpha;
    descriptors[3].destinationRGBFactor =
        BlendFactor::one_minus_destination_alpha;
    descriptors[3].sourceAlphaFactor = BlendFactor::zero;
    descriptors[3].destinationAlphaFactor = BlendFactor::one;

    for (std::size_t index = 4; index < descriptors.size(); ++index)
    {
        descriptors[index].sourceRGBFactor = BlendFactor::one;
        descriptors[index].destinationRGBFactor = BlendFactor::one;
        descriptors[index].sourceAlphaFactor = BlendFactor::one;
        descriptors[index].destinationAlphaFactor = BlendFactor::one;
    }
    descriptors[4].rgbOperation = BlendOperation::add;
    descriptors[4].alphaOperation = BlendOperation::subtract;
    descriptors[5].rgbOperation = BlendOperation::subtract;
    descriptors[5].alphaOperation = BlendOperation::reverse_subtract;
    descriptors[6].rgbOperation = BlendOperation::reverse_subtract;
    descriptors[6].alphaOperation = BlendOperation::min;
    descriptors[7].rgbOperation = BlendOperation::min;
    descriptors[7].alphaOperation = BlendOperation::max;
    descriptors[8].rgbOperation = BlendOperation::max;
    descriptors[8].alphaOperation = BlendOperation::add;
    return descriptors;
}

struct PipelineSet
{
    MetalRenderPipelineHandle seed = nullptr;
    std::array<MetalRenderPipelineHandle, WIDTH> cells{};
};

MetalRenderPipelineHandle requirePipeline(
    MetalRenderPipelineFamilyCache& cache,
    const BlendAttachmentDesc&      descriptor)
{
    const auto pipeline = cache.pipeline(descriptor);
    EXPECT(pipeline.has_value());
    return pipeline ? *pipeline : nullptr;
}

PipelineSet preparePipelines(MetalRenderPipelineFamilyCache& cache)
{
    PipelineSet result;

    BlendAttachmentDesc invalid;
    invalid.writeMask = static_cast<ColorWriteMask>(16);
    EXPECT(!cache.pipeline(invalid).has_value());
    EXPECT(cache.hitCount() == 0);
    EXPECT(cache.missCount() == 0);
    EXPECT(cache.entryCount() == 0);

    const BlendAttachmentDesc seed;
    result.seed = requirePipeline(cache, seed);
    BlendAttachmentDesc seed_equivalent;
    seed_equivalent.rgbOperation = BlendOperation::max;
    seed_equivalent.sourceRGBFactor = BlendFactor::destination_color;
    seed_equivalent.alphaOperation = BlendOperation::min;
    seed_equivalent.destinationAlphaFactor =
        BlendFactor::one_minus_source_color;
    EXPECT(requirePipeline(cache, seed_equivalent) == result.seed);

    const auto descriptors = cellDescriptors();
    for (std::size_t index = 0; index < descriptors.size(); ++index)
    {
        result.cells[index] = requirePipeline(cache, descriptors[index]);
    }

    BlendAttachmentDesc alpha_alias = descriptors[0];
    alpha_alias.destinationAlphaFactor =
        BlendFactor::one_minus_source_color;
    EXPECT(requirePipeline(cache, alpha_alias) == result.cells[0]);

    BlendAttachmentDesc ignored_alpha_factors = descriptors[6];
    ignored_alpha_factors.sourceAlphaFactor = BlendFactor::zero;
    ignored_alpha_factors.destinationAlphaFactor =
        BlendFactor::destination_color;
    EXPECT(requirePipeline(cache, ignored_alpha_factors) == result.cells[6]);

    BlendAttachmentDesc ignored_min_max_factors = descriptors[7];
    ignored_min_max_factors.sourceRGBFactor = BlendFactor::zero;
    ignored_min_max_factors.destinationRGBFactor = BlendFactor::source_alpha;
    ignored_min_max_factors.sourceAlphaFactor = BlendFactor::source_color;
    ignored_min_max_factors.destinationAlphaFactor =
        BlendFactor::one_minus_destination_color;
    EXPECT(requirePipeline(cache, ignored_min_max_factors) == result.cells[7]);

    BlendAttachmentDesc no_write = descriptors[2];
    no_write.writeMask = ColorWriteMask::none;
    const auto no_write_pipeline = requirePipeline(cache, no_write);
    BlendAttachmentDesc no_write_equivalent;
    no_write_equivalent.writeMask = ColorWriteMask::none;
    EXPECT(requirePipeline(cache, no_write_equivalent) == no_write_pipeline);

    BlendAttachmentDesc alpha_only;
    alpha_only.blendingEnabled = true;
    alpha_only.writeMask = ColorWriteMask::alpha;
    const auto alpha_only_pipeline = requirePipeline(cache, alpha_only);
    BlendAttachmentDesc alpha_only_equivalent = alpha_only;
    alpha_only_equivalent.rgbOperation = BlendOperation::subtract;
    alpha_only_equivalent.sourceRGBFactor = BlendFactor::destination_alpha;
    EXPECT(requirePipeline(cache, alpha_only_equivalent) ==
           alpha_only_pipeline);

    BlendAttachmentDesc rgb_only;
    rgb_only.blendingEnabled = true;
    rgb_only.writeMask = RGB_WRITE_MASK;
    const auto rgb_only_pipeline = requirePipeline(cache, rgb_only);
    BlendAttachmentDesc rgb_only_equivalent = rgb_only;
    rgb_only_equivalent.alphaOperation = BlendOperation::reverse_subtract;
    rgb_only_equivalent.destinationAlphaFactor = BlendFactor::source_alpha;
    EXPECT(requirePipeline(cache, rgb_only_equivalent) == rgb_only_pipeline);

    EXPECT(cache.hitCount() == 7);
    EXPECT(cache.missCount() == 13);
    EXPECT(cache.entryCount() == 13);

    const auto seed_key = makeBlendAttachmentKey(seed, TEST_COLOR_FORMAT);
    EXPECT(seed_key.has_value());
    for (std::size_t index = 0; index < result.cells.size(); ++index)
    {
        EXPECT(result.cells[index] != nullptr);
        const auto key = makeBlendAttachmentKey(descriptors[index],
                                                 TEST_COLOR_FORMAT);
        EXPECT(key.has_value());
        EXPECT(key != seed_key);
        for (std::size_t later = index + 1;
             later < result.cells.size();
             ++later)
        {
            EXPECT(key != makeBlendAttachmentKey(descriptors[later],
                                                  TEST_COLOR_FORMAT));
        }
    }

    const auto hits_before = cache.hitCount();
    const auto misses_before = cache.missCount();
    const auto entries_before = cache.entryCount();
    invalid = BlendAttachmentDesc{};
    invalid.alphaOperation = static_cast<BlendOperation>(255);
    EXPECT(!cache.pipeline(invalid).has_value());
    EXPECT(cache.hitCount() == hits_before);
    EXPECT(cache.missCount() == misses_before);
    EXPECT(cache.entryCount() == entries_before);
    return result;
}

std::optional<MetalPrivateTexture> createTarget(id<MTLDevice> device)
{
    MetalTextureDescriptor descriptor;
    descriptor.format = PixelFormat::rgba8_unorm;
    descriptor.width = WIDTH;
    descriptor.height = HEIGHT;
    descriptor.mipLevels = 1;
    descriptor.usage = MetalTextureUsage::render_target;
    descriptor.label = "Firestorm blend/pipeline 9x1 target";
    return createPrivateTexture((__bridge void*)device, descriptor);
}

bool encodeColorDraw(MetalFrameContext&           frames,
                     const MetalFrameLease&      lease,
                     id<MTLRenderCommandEncoder> encoder,
                     const FragmentColorBytes&   color)
{
    const auto allocation =
        frames.allocate(lease.token, sizeof(color), alignof(FragmentColorBytes));
    EXPECT(allocation.has_value());
    if (!allocation)
    {
        return false;
    }

    std::memcpy(allocation->bytes, &color, sizeof(color));
    [encoder setFragmentBuffer:(__bridge id<MTLBuffer>)lease.buffer
                        offset:allocation->offset
                       atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:3];
    return true;
}

void validateReadback(const MetalTextureReadback& readback)
{
    EXPECT(readback.format == PixelFormat::rgba8_unorm);
    EXPECT(readback.region.x == 0);
    EXPECT(readback.region.y == 0);
    EXPECT(readback.region.width == WIDTH);
    EXPECT(readback.region.height == HEIGHT);
    EXPECT(readback.region.mipLevel == 0);
    EXPECT(readback.region.slice == 0);
    EXPECT(readback.bytesPerRow >= ACTIVE_ROW_BYTES);
    EXPECT(readback.bytesPerImage >= readback.bytesPerRow);
    EXPECT(readback.bytes.size() >= readback.bytesPerImage);
    if (readback.bytesPerRow < ACTIVE_ROW_BYTES ||
        readback.bytes.size() < ACTIVE_ROW_BYTES)
    {
        return;
    }

    for (std::size_t offset = 0; offset < ACTIVE_ROW_BYTES; ++offset)
    {
        const std::uint8_t actual =
            std::to_integer<std::uint8_t>(readback.bytes[offset]);
        if (actual != EXPECTED_PIXELS[offset])
        {
            std::cerr << "FAIL blend/pipeline cell=" << offset / 4
                      << " channel=" << offset % 4
                      << " expected="
                      << static_cast<unsigned>(EXPECTED_PIXELS[offset])
                      << " actual=" << static_cast<unsigned>(actual) << '\n';
            ++gFailures;
        }
    }
}

void runGpuTest(id<MTLDevice> device,
                id<MTLLibrary> library,
                id<MTLCommandQueue> queue)
{
    MetalRenderPipelineFamilyCache cache((__bridge void*)device,
                                          (__bridge void*)library,
                                          familyDescriptor());
    EXPECT(cache.valid());
    if (!cache.valid())
    {
        return;
    }
    const PipelineSet pipelines = preparePipelines(cache);
    if (pipelines.seed == nullptr)
    {
        return;
    }

    const auto target = createTarget(device);
    EXPECT(target.has_value());
    if (!target)
    {
        return;
    }
    id<MTLTexture> native_target =
        (__bridge id<MTLTexture>)target->nativeHandle();
    EXPECT(native_target.storageMode == MTLStorageModePrivate);
    EXPECT(native_target.pixelFormat == MTLPixelFormatRGBA8Unorm);
    EXPECT(target->usage() == MetalTextureUsage::render_target);

    MetalFrameContext frames((__bridge void*)device, 1024);
    EXPECT(frames.valid());
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
    command_buffer.label = @"Firestorm exact blend/pipeline validation";

    MTLRenderPassDescriptor* render_pass =
        [MTLRenderPassDescriptor renderPassDescriptor];
    render_pass.colorAttachments[0].texture = native_target;
    render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    render_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

    id<MTLRenderCommandEncoder> encoder =
        [command_buffer renderCommandEncoderWithDescriptor:render_pass];
    EXPECT(encoder != nil);
    if (encoder == nil)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }
    encoder.label = @"Firestorm 9x1 blend/pipeline atlas";
    [encoder setViewport:MTLViewport{ 0.0, 0.0,
                                     static_cast<double>(WIDTH),
                                     static_cast<double>(HEIGHT),
                                     0.0, 1.0 }];

    bool encoded = true;
    for (std::uint32_t x = 0; x < WIDTH; ++x)
    {
        [encoder setScissorRect:MTLScissorRect{ x, 0, 1, 1 }];
        [encoder setRenderPipelineState:
            (__bridge id<MTLRenderPipelineState>)pipelines.seed];
        encoded = encodeColorDraw(frames, *lease, encoder,
                                  DESTINATIONS[x]) && encoded;
        [encoder setRenderPipelineState:
            (__bridge id<MTLRenderPipelineState>)pipelines.cells[x]];
        encoded = encodeColorDraw(frames, *lease, encoder,
                                  SOURCES[x]) && encoded;
    }
    [encoder endEncoding];
    if (!encoded)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    std::mutex publication_mutex;
    std::optional<MetalTextureReadback> publication;
    std::uint64_t published_serial = 0;
    dispatch_semaphore_t published = dispatch_semaphore_create(0);

    MetalTransferBatch batch((__bridge void*)device,
                             frames,
                             *lease,
                             (__bridge void*)command_buffer,
                             256);
    EXPECT(batch.valid());
    if (!batch.valid())
    {
        return;
    }
    const MetalTextureRegion region{ 0, 0, WIDTH, HEIGHT, 0, 0 };
    const auto readback_status = batch.readbackTexture(
        *target,
        region,
        [&](std::uint64_t serial, MetalTextureReadback readback) {
            {
                std::lock_guard<std::mutex> lock(publication_mutex);
                published_serial = serial;
                publication = std::move(readback);
            }
            dispatch_semaphore_signal(published);
        });
    EXPECT(readback_status == MetalTransferStatus::encoded);
    if (readback_status != MetalTransferStatus::encoded)
    {
        batch.cancel();
        return;
    }

    auto completion = batch.finish();
    EXPECT(completion.has_value());
    if (!completion)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    const auto submission_serial = frames.submit(
        lease->token,
        (__bridge void*)command_buffer,
        std::move(*completion));
    EXPECT(submission_serial.has_value());
    if (!submission_serial)
    {
        EXPECT(frames.cancel(lease->token));
        return;
    }

    {
        std::lock_guard<std::mutex> lock(publication_mutex);
        EXPECT(!publication.has_value());
    }
    [command_buffer commit];
    requireSignal(published, command_buffer, "blend/pipeline atlas readback");
    EXPECT(command_buffer.status == MTLCommandBufferStatusCompleted);
    EXPECT(command_buffer.error == nil);

    std::lock_guard<std::mutex> lock(publication_mutex);
    EXPECT(publication.has_value());
    EXPECT(published_serial == *submission_serial);
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
        testKeyContract();

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        EXPECT(device != nil);
        if (device == nil)
        {
            return EXIT_FAILURE;
        }

        id<MTLLibrary> library = loadLibrary(device, metallib_path);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        EXPECT(queue != nil);
        if (library != nil)
        {
            testInvalidFamilies(device, library);
        }
        if (library != nil && queue != nil)
        {
            runGpuTest(device, library, queue);
        }
    }

    if (gFailures != 0)
    {
        std::cerr << gFailures << " Metal blend/pipeline test(s) failed\n";
        return EXIT_FAILURE;
    }

    std::cout << "PASS Metal canonical pipeline family and exact 9x1 blending\n";
    return EXIT_SUCCESS;
}
