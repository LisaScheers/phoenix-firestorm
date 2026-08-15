/**
 * @file fxaa-semantic-test-objc.mm
 * @brief Source-pinned CGL and Metal semantic comparison for the FXAA array.
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

#define GL_SILENCE_DEPRECATION 1

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>

#include "firestorm-declared-programs.h"
#include "firestorm_metal_fxaa_semantic_config.h"
#include "llmetalprogram.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#ifndef FIRESTORM_METAL_ORACLE_GIT_EXECUTABLE
#error "FIRESTORM_METAL_ORACLE_GIT_EXECUTABLE must be provided by CMake"
#endif

#ifndef FIRESTORM_METAL_ORACLE_PINNED_COMMIT
#error "FIRESTORM_METAL_ORACLE_PINNED_COMMIT must be provided by CMake"
#endif

namespace
{

constexpr std::string_view kPinnedCommit =
    FIRESTORM_METAL_ORACLE_PINNED_COMMIT;
constexpr std::string_view kOracleGitExecutable =
    FIRESTORM_METAL_ORACLE_GIT_EXECUTABLE;
constexpr int kWidth = 128;
constexpr int kHeight = 64;
constexpr std::size_t kChannels = 4;
constexpr std::size_t kPixelBytes = kChannels;
constexpr std::size_t kImageBytes =
    static_cast<std::size_t>(kWidth) * static_cast<std::size_t>(kHeight) *
    kPixelBytes;
constexpr std::size_t kGLRepeats = 8;
constexpr std::size_t kMinimumChangedPixels = 256;
constexpr std::uint8_t kComparisonTolerance = 1;

using firestorm::metal::MetalProgramDescriptor;
using firestorm::metal::MetalProgramLibrary;
using firestorm::metal::MetalResourceAccess;
using firestorm::metal::MetalTextureDataType;
using firestorm::metal::MetalTextureType;
using firestorm::metal::MetalVertexFormat;
using firestorm::metal::MetalVertexStepFunction;
using firestorm::metal::PixelFormat;
using firestorm::metal::declaredMetalPrograms;

struct Options
{
    std::filesystem::path metallib;
    std::filesystem::path artifactRoot;
    std::filesystem::path oracleWorktree;
};

struct Variant
{
    std::string_view id;
    std::string_view preset;
    std::uint16_t sourceIndex;
    std::string_view reflectionSha256;
};

constexpr std::array<Variant, 4> kVariants{{
    {"fxaa_low", "12", 0,
     "940abf1b4b98ae1e35d4c2da146f199a875dfed3fd12f809815783fde7746792"},
    {"fxaa_medium", "23", 1,
     "2ad770630a1b266475a0e9d0bad3fd0b7a02fc4222d77cdfa39769464dd600d0"},
    {"fxaa_high", "28", 2,
     "dff29c7a9c694521633704ba8617d801a2248b526bdfe0f7bdfaec7f57802f3e"},
    {"fxaa", "39", 3,
     "cb6b9c8bf968154e218a4ab4ce718524d42cd38c3ae28fb3958289e162c77f70"},
}};

struct ObjectContract
{
    std::string_view stage;
    std::string_view filename;
    std::string_view sourceLabel;
    bool feature;
};

constexpr std::array<ObjectContract, 4> kVertexObjects{{
    {"vertex", "00-postDeferredV.vert",
     "indra/newview/app_settings/shaders/class1/deferred/postDeferredV.glsl", false},
    {"vertex", "01-atmosphericsVarsV.vert",
     "indra/newview/app_settings/shaders/class1/windlight/atmosphericsVarsV.glsl", true},
    {"vertex", "02-textureUtilV.vert",
     "indra/newview/app_settings/shaders/class1/deferred/textureUtilV.glsl", true},
    {"vertex", "03-nonindexedTextureV.vert",
     "indra/newview/app_settings/shaders/class1/objects/nonindexedTextureV.glsl", true},
}};

constexpr std::array<ObjectContract, 8> kFragmentObjects{{
    {"fragment", "00-fxaaF.frag",
     "indra/newview/app_settings/shaders/class1/deferred/fxaaF.glsl", false},
    {"fragment", "01-globalF.frag",
     "indra/newview/app_settings/shaders/class1/deferred/globalF.glsl", true},
    {"fragment", "02-srgbF.frag",
     "indra/newview/app_settings/shaders/class1/environment/srgbF.glsl", true},
    {"fragment", "03-atmosphericsVarsF.frag",
     "indra/newview/app_settings/shaders/class1/windlight/atmosphericsVarsF.glsl", true},
    {"fragment", "04-deferredUtil.frag",
     "indra/newview/app_settings/shaders/class1/deferred/deferredUtil.glsl", true},
    {"fragment", "05-gammaF.frag",
     "indra/newview/app_settings/shaders/class1/windlight/gammaF.glsl", true},
    {"fragment", "06-atmosphericsFuncs.frag",
     "indra/newview/app_settings/shaders/class1/windlight/atmosphericsFuncs.glsl", true},
    {"fragment", "07-atmosphericsF.frag",
     "indra/newview/app_settings/shaders/class1/windlight/atmosphericsF.glsl", true},
}};

struct GLProgram
{
    GLuint program = 0;

    ~GLProgram()
    {
        if (program != 0)
        {
            glDeleteProgram(program);
        }
    }

    GLProgram() = default;
    GLProgram(const GLProgram&) = delete;
    GLProgram& operator=(const GLProgram&) = delete;
    GLProgram(GLProgram&& other) noexcept : program(other.program)
    {
        other.program = 0;
    }
    GLProgram& operator=(GLProgram&& other) noexcept
    {
        if (this != &other)
        {
            if (program != 0)
            {
                glDeleteProgram(program);
            }
            program = other.program;
            other.program = 0;
        }
        return *this;
    }
};

struct alignas(16) Vertex
{
    float x;
    float y;
    float z;
    float padding;
};

struct VertexUniforms
{
    float tcScale[2];
    float screenRes[2];
};

struct GLState
{
    GLuint vao = 0;
    GLuint vertexBuffer = 0;
    GLuint inputTexture = 0;
    GLuint depthInputTexture = 0;
    GLuint outputTexture = 0;
    GLuint outputDepthTexture = 0;
    GLuint framebuffer = 0;

    ~GLState()
    {
        if (framebuffer != 0)
        {
            glDeleteFramebuffers(1, &framebuffer);
        }
        if (outputDepthTexture != 0)
        {
            glDeleteTextures(1, &outputDepthTexture);
        }
        if (outputTexture != 0)
        {
            glDeleteTextures(1, &outputTexture);
        }
        if (depthInputTexture != 0)
        {
            glDeleteTextures(1, &depthInputTexture);
        }
        if (inputTexture != 0)
        {
            glDeleteTextures(1, &inputTexture);
        }
        if (vertexBuffer != 0)
        {
            glDeleteBuffers(1, &vertexBuffer);
        }
        if (vao != 0)
        {
            glDeleteVertexArrays(1, &vao);
        }
    }

    GLState() = default;
    GLState(const GLState&) = delete;
    GLState& operator=(const GLState&) = delete;
    GLState(GLState&& other) noexcept
        : vao(other.vao),
          vertexBuffer(other.vertexBuffer),
          inputTexture(other.inputTexture),
          depthInputTexture(other.depthInputTexture),
          outputTexture(other.outputTexture),
          outputDepthTexture(other.outputDepthTexture),
          framebuffer(other.framebuffer)
    {
        other.vao = 0;
        other.vertexBuffer = 0;
        other.inputTexture = 0;
        other.depthInputTexture = 0;
        other.outputTexture = 0;
        other.outputDepthTexture = 0;
        other.framebuffer = 0;
    }
    GLState& operator=(GLState&&) = delete;
};

struct CGLContext
{
    CGLContextObj context = nullptr;

    ~CGLContext()
    {
        if (context != nullptr)
        {
            CGLSetCurrentContext(nullptr);
            CGLReleaseContext(context);
        }
    }

    CGLContext() = default;
    CGLContext(const CGLContext&) = delete;
    CGLContext& operator=(const CGLContext&) = delete;
    CGLContext(CGLContext&& other) noexcept : context(other.context)
    {
        other.context = nullptr;
    }
    CGLContext& operator=(CGLContext&&) = delete;
};

struct GLRenderResult
{
    std::vector<std::uint8_t> color;
    std::vector<float> depth;
};

struct MetalRenderResult
{
    std::vector<std::uint8_t> color;
};

[[noreturn]] void fail(const std::string& message)
{
    throw std::runtime_error(message);
}

void require(bool condition, const std::string& message)
{
    if (!condition)
    {
        fail(message);
    }
}

std::string toString(std::string_view value)
{
    return std::string(value.data(), value.size());
}

std::string readFile(const std::filesystem::path& path)
{
    std::ifstream input(path, std::ios::binary);
    require(static_cast<bool>(input), "cannot read " + path.string());
    std::ostringstream output;
    output << input.rdbuf();
    require(static_cast<bool>(input) || input.eof(),
            "cannot read " + path.string());
    return output.str();
}

bool hasSuffix(std::string_view value, std::string_view suffix)
{
    return value.size() >= suffix.size() &&
           value.substr(value.size() - suffix.size()) == suffix;
}

std::size_t countSubstring(std::string_view text, std::string_view needle)
{
    if (needle.empty())
    {
        return 0;
    }
    std::size_t count = 0;
    std::size_t offset = 0;
    while (true)
    {
        const std::size_t found = text.find(needle, offset);
        if (found == std::string_view::npos)
        {
            return count;
        }
        ++count;
        offset = found + needle.size();
    }
}

Options parseOptions(int argc, const char* argv[])
{
    Options options;
    for (int index = 1; index < argc; index += 2)
    {
        require(index + 1 < argc, "option without a value");
        const std::string_view flag(argv[index]);
        const std::filesystem::path value(argv[index + 1]);
        require(!value.empty(), "empty option value");
        if (flag == "--metallib" && options.metallib.empty())
        {
            options.metallib = value;
        }
        else if (flag == "--artifact-root" && options.artifactRoot.empty())
        {
            options.artifactRoot = value;
        }
        else if (flag == "--oracle-worktree" && options.oracleWorktree.empty())
        {
            options.oracleWorktree = value;
        }
        else
        {
            fail("unknown or repeated option " + toString(flag));
        }
    }
    require(!options.metallib.empty() && !options.artifactRoot.empty() &&
                !options.oracleWorktree.empty(),
            "usage: fxaa-semantic-test --metallib PATH --artifact-root PATH "
            "--oracle-worktree PATH");
    require(std::filesystem::is_regular_file(options.metallib),
            "metallib is not a regular file: " + options.metallib.string());
    require(std::filesystem::is_directory(options.artifactRoot),
            "artifact root is not a directory: " + options.artifactRoot.string());
    require(std::filesystem::is_directory(options.oracleWorktree),
            "oracle worktree is not a directory: " + options.oracleWorktree.string());
    return options;
}

std::uint8_t sourceLuma(std::uint8_t red, std::uint8_t green, std::uint8_t blue)
{
    const double value = 0.299 * static_cast<double>(red) +
                         0.587 * static_cast<double>(green) +
                         0.144 * static_cast<double>(blue);
    const long rounded = std::lround(value);
    return static_cast<std::uint8_t>(std::clamp(rounded, 0L, 255L));
}

std::size_t pixelOffset(int x, int y)
{
    require(x >= 0 && x < kWidth && y >= 0 && y < kHeight,
            "chart coordinate outside bounds");
    return (static_cast<std::size_t>(y) * static_cast<std::size_t>(kWidth) +
            static_cast<std::size_t>(x)) *
           kPixelBytes;
}

void putPixel(std::vector<std::uint8_t>& pixels,
              int x,
              int y,
              std::uint8_t red,
              std::uint8_t green,
              std::uint8_t blue)
{
    const std::size_t offset = pixelOffset(x, y);
    pixels[offset] = red;
    pixels[offset + 1] = green;
    pixels[offset + 2] = blue;
    // This is exactly glowcombineFXAAF.glsl's RGBL preparation contract.
    pixels[offset + 3] = sourceLuma(red, green, blue);
}

std::vector<std::uint8_t> makeChart()
{
    std::vector<std::uint8_t> pixels(kImageBytes);
    for (int y = 0; y < kHeight; ++y)
    {
        for (int x = 0; x < kWidth; ++x)
        {
            const int band = x / 16;
            bool light = false;
            std::uint8_t darkRed = 12;
            std::uint8_t darkGreen = 16;
            std::uint8_t darkBlue = 24;
            std::uint8_t lightRed = 238;
            std::uint8_t lightGreen = 231;
            std::uint8_t lightBlue = 219;
            switch (band)
            {
                case 0: // Vertical high-contrast edge.
                    light = x >= 8;
                    break;
                case 1: // Horizontal high-contrast edge.
                    light = y >= 32;
                    break;
                case 2: // 45 degree diagonal.
                    light = (x - 32) >= y / 4;
                    break;
                case 3: // Shallow diagonal.
                    light = y >= 18 + (x - 48) / 2;
                    darkRed = 25;
                    darkGreen = 42;
                    darkBlue = 70;
                    lightRed = 232;
                    lightGreen = 156;
                    lightBlue = 82;
                    break;
                case 4: // Steep diagonal.
                    light = (x - 64) >= 3 + y / 8;
                    darkRed = 28;
                    darkGreen = 12;
                    darkBlue = 45;
                    lightRed = 198;
                    lightGreen = 232;
                    lightBlue = 96;
                    break;
                case 5: // Alternating stairs.
                    light = (x - 80) >= y / 4 + ((y / 3) & 1);
                    darkRed = 8;
                    darkGreen = 42;
                    darkBlue = 37;
                    lightRed = 246;
                    lightGreen = 179;
                    lightBlue = 68;
                    break;
                case 6: // Checker plus deliberately low contrast rows.
                    light = ((x / 2) + (y / 2)) % 2 == 0;
                    if (y >= 32)
                    {
                        darkRed = 104;
                        darkGreen = 112;
                        darkBlue = 118;
                        lightRed = 128;
                        lightGreen = 136;
                        lightBlue = 142;
                    }
                    break;
                default: // Mixed thin horizontal, vertical, and diagonal edges.
                    light = ((x - 112) + y / 5) % 7 < 3;
                    darkRed = 18;
                    darkGreen = 64;
                    darkBlue = 112;
                    lightRed = 228;
                    lightGreen = 84;
                    lightBlue = 188;
                    break;
            }
            putPixel(pixels, x, y,
                     light ? lightRed : darkRed,
                     light ? lightGreen : darkGreen,
                     light ? lightBlue : darkBlue);
        }
    }

    // Four deliberately distinct corners expose a vertical-coordinate mistake.
    for (int y = 0; y < 4; ++y)
    {
        for (int x = 0; x < 4; ++x)
        {
            putPixel(pixels, x, y, 255, 0, 0);
            putPixel(pixels, kWidth - 1 - x, y, 0, 255, 0);
            putPixel(pixels, x, kHeight - 1 - y, 0, 0, 255);
            putPixel(pixels, kWidth - 1 - x, kHeight - 1 - y, 255, 255, 0);
        }
    }
    return pixels;
}

std::vector<float> makeDepthChart()
{
    std::vector<float> depths(static_cast<std::size_t>(kWidth) *
                              static_cast<std::size_t>(kHeight));
    for (int y = 0; y < kHeight; ++y)
    {
        for (int x = 0; x < kWidth; ++x)
        {
            const std::size_t offset = static_cast<std::size_t>(y) *
                                           static_cast<std::size_t>(kWidth) +
                                       static_cast<std::size_t>(x);
            const int pattern = (x * 13 + y * 17) % 701;
            depths[offset] = 0.1F + static_cast<float>(pattern) / 1000.0F;
        }
    }
    return depths;
}

template <typename T>
std::vector<T> flipRows(const std::vector<T>& input, std::size_t rowWidth)
{
    require(rowWidth != 0 && input.size() % rowWidth == 0,
            "invalid image row geometry");
    std::vector<T> output(input.size());
    const std::size_t rows = input.size() / rowWidth;
    for (std::size_t row = 0; row < rows; ++row)
    {
        const std::size_t sourceOffset = row * rowWidth;
        const std::size_t targetOffset = (rows - 1 - row) * rowWidth;
        std::copy_n(input.begin() + static_cast<std::ptrdiff_t>(sourceOffset),
                    static_cast<std::ptrdiff_t>(rowWidth),
                    output.begin() + static_cast<std::ptrdiff_t>(targetOffset));
    }
    return output;
}

std::uint64_t fnv1a64(const std::vector<std::uint8_t>& bytes)
{
    std::uint64_t hash = 14695981039346656037ULL;
    for (const std::uint8_t byte : bytes)
    {
        hash ^= byte;
        hash *= 1099511628211ULL;
    }
    return hash;
}

std::string trimTrailingLineEndings(std::string value)
{
    while (!value.empty() &&
           (value.back() == '\n' || value.back() == '\r'))
    {
        value.pop_back();
    }
    return value;
}

struct GitResult
{
    int exitCode = 0;
    std::string output;
};

NSString* oracleGitExecutable()
{
    require(!kOracleGitExecutable.empty(),
            "CMake configured an empty Git executable for oracle verification");
    const std::string path = toString(kOracleGitExecutable);
    NSString* executable = [NSString stringWithUTF8String:path.c_str()];
    require(executable != nil && executable.length != 0,
            "CMake configured a non-UTF-8 Git executable for oracle verification");
    require([[NSFileManager defaultManager] isExecutableFileAtPath:executable],
            "CMake configured Git executable is not runnable: " + path);
    return executable;
}

GitResult runGitResult(const std::filesystem::path& worktree,
                       const std::vector<std::string>& arguments)
{
    NSString* worktreePath =
        [NSString stringWithUTF8String:worktree.string().c_str()];
    require(worktreePath != nil, "oracle worktree path is not UTF-8");

    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:oracleGitExecutable()];
    task.currentDirectoryURL = [NSURL fileURLWithPath:worktreePath];
    NSMutableArray<NSString*>* taskArguments = [[NSMutableArray alloc] init];
    [taskArguments addObject:@"--no-optional-locks"];
    for (const std::string& argument : arguments)
    {
        NSString* value = [NSString stringWithUTF8String:argument.c_str()];
        require(value != nil, "git argument is not UTF-8");
        [taskArguments addObject:value];
    }
    task.arguments = taskArguments;
    NSPipe* output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = output;

    NSError* error = nil;
    if (![task launchAndReturnError:&error])
    {
        const char* description = error.localizedDescription.UTF8String;
        fail("cannot launch git: " +
             std::string(description == nullptr ? "unknown error" : description));
    }
    NSData* bytes = [[output fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    const char* data = static_cast<const char*>(bytes.bytes);
    const std::string result(data == nullptr ? "" : data, bytes.length);
    return {task.terminationStatus, trimTrailingLineEndings(result)};
}

std::string runGit(const std::filesystem::path& worktree,
                   const std::vector<std::string>& arguments)
{
    GitResult result = runGitResult(worktree, arguments);
    if (result.exitCode != 0)
    {
        fail("git failed: " + result.output);
    }
    return result.output;
}

void verifyOracleWorktree(const std::filesystem::path& oracleWorktree)
{
    std::error_code canonicalError;
    const std::filesystem::path canonicalWorktree =
        std::filesystem::weakly_canonical(oracleWorktree, canonicalError);
    require(!canonicalError,
            "cannot canonicalize oracle worktree: " + canonicalError.message());
    const std::string reportedRoot =
        runGit(oracleWorktree, {"rev-parse", "--show-toplevel"});
    std::error_code rootError;
    const std::filesystem::path canonicalRoot =
        std::filesystem::weakly_canonical(reportedRoot, rootError);
    require(!rootError, "cannot canonicalize git worktree root: " + rootError.message());
    require(canonicalRoot == canonicalWorktree,
            "oracle worktree is not its canonical Git root: " +
                canonicalWorktree.string() + " versus " + canonicalRoot.string());

    const std::string revision = runGit(oracleWorktree, {"rev-parse", "HEAD"});
    require(revision == kPinnedCommit,
            "oracle worktree is not pinned to " + toString(kPinnedCommit) +
                ": " + revision);
    const GitResult detached =
        runGitResult(oracleWorktree, {"symbolic-ref", "-q", "HEAD"});
    require(detached.exitCode == 1 && detached.output.empty(),
            "oracle worktree must be detached at the pinned commit");
    const std::string status =
        runGit(oracleWorktree, {"status", "--porcelain=v1", "--untracked-files=all"});
    require(status.empty(), "oracle worktree is not clean: " + status);
}

void requireContains(const std::filesystem::path& path,
                     std::string_view needle,
                     const char* description)
{
    const std::string source = readFile(path);
    require(source.find(needle) != std::string::npos,
            std::string("pinned source lacks ") + description + ": " + path.string());
}

void verifyBaselineRuntimeContracts(const std::filesystem::path& oracleWorktree)
{
    const auto source = [&oracleWorktree](std::string_view relative) {
        return oracleWorktree / std::filesystem::path(toString(relative));
    };
    requireContains(source("indra/newview/llviewershadermgr.cpp"),
                    "{ {\"12\", \"Low\"},\n"
                    "                                                                             {\"23\", \"Medium\"},\n"
                    "                                                                             {\"28\", \"High\"},\n"
                    "                                                                             {\"39\", \"Ultra\"} }",
                    "the ordered FXAA preset table");
    requireContains(source("indra/newview/llviewershadermgr.cpp"),
                    "gFXAAProgram[i].mShaderFiles.push_back(make_pair(\"deferred/postDeferredV.glsl\", GL_VERTEX_SHADER));\n"
                    "                gFXAAProgram[i].mShaderFiles.push_back(make_pair(\"deferred/fxaaF.glsl\", GL_FRAGMENT_SHADER));",
                    "the FXAA source-object pair");
    requireContains(source("indra/newview/pipeline.cpp"),
                    "mFXAAMap.bindTexture(0, channel, LLTexUnit::TFO_BILINEAR);",
                    "the FXAA bilinear source sampler");
    requireContains(source("indra/newview/pipeline.cpp"),
                    "shader->uniform2f(LLShaderMgr::FXAA_TC_SCALE, scale_x, scale_y);",
                    "the FXAA tc_scale uniform");
    requireContains(source("indra/newview/pipeline.cpp"),
                    "shader->uniform2f(LLShaderMgr::FXAA_RCP_SCREEN_RES, 1.f / width * scale_x, 1.f / height * scale_y);",
                    "the FXAA reciprocal-resolution uniform");
    requireContains(source("indra/newview/pipeline.cpp"),
                    "gGL.getTexUnit(depth_channel)->bind(&mRT->deferredScreen, true);",
                    "the baseline FXAA depth input");
    requireContains(source("indra/llrender/llrendertarget.cpp"),
                    "gGL.getTexUnit(0)->setTextureAddressMode(LLTexUnit::TAM_MIRROR);",
                    "the render-target mirror-repeat sampler");
    requireContains(source("indra/newview/app_settings/shaders/class1/interface/glowcombineFXAAF.glsl"),
                    "dot(col.rgb, vec3(0.299, 0.587, 0.144))",
                    "the RGBL luma contract");
    requireContains(source("indra/newview/app_settings/shaders/class1/deferred/fxaaF.glsl"),
                    "uniform sampler2D diffuseMap;\nuniform sampler2D depthMap;",
                    "the baseline depth-writing FXAA body");
}

std::string replaceExactlyOnce(std::string value,
                               std::string_view before,
                               std::string_view after,
                               const char* description)
{
    const std::size_t first = value.find(before);
    require(first != std::string::npos,
            std::string("expected source text is absent: ") + description);
    require(value.find(before, first + before.size()) == std::string::npos,
            std::string("expected source text is ambiguous: ") + description);
    value.replace(first, before.size(), after);
    return value;
}

std::string approvedCurrentSource(std::string_view label, std::string source)
{
    if (label == "indra/newview/app_settings/shaders/class1/deferred/fxaaF.glsl")
    {
        source = replaceExactlyOnce(
            std::move(source),
            "uniform sampler2D diffuseMap;\nuniform sampler2D depthMap;\n",
            "uniform sampler2D diffuseMap;\n#ifndef FXAA_NO_DEPTH_WRITE\n"
            "uniform sampler2D depthMap;\n#endif\n",
            "the reviewed FXAA depth sampler guard");
        source = replaceExactlyOnce(
            std::move(source),
            "    frag_color = diff;\n\n    gl_FragDepth = texture(depthMap, vary_fragcoord.xy).r;\n",
            "    frag_color = diff;\n\n#ifndef FXAA_NO_DEPTH_WRITE\n"
            "    gl_FragDepth = texture(depthMap, vary_fragcoord.xy).r;\n#endif\n",
            "the reviewed FXAA depth-write guard");
        return source;
    }
    if (label == "indra/newview/app_settings/shaders/class1/deferred/deferredUtil.glsl")
    {
        source = replaceExactlyOnce(
            std::move(source),
            "void calcDiffuseSpecular(vec3 baseColor, float metallic, inout vec3 diffuseColor, inout vec3 specularColor)",
            "void calcDiffuseSpecular(vec3 baseColor, float metallic, out vec3 diffuseColor, out vec3 specularColor)",
            "the reviewed deferredUtil output-parameter compatibility change");
        require(hasSuffix(source, "\n\n"),
                "pinned deferredUtil does not have the reviewed trailing newline");
        source.pop_back();
        return source;
    }
    return source;
}

std::string preamble(std::string_view stage,
                     bool feature,
                     const Variant& variant)
{
    const std::string_view stageDefine =
        stage == "vertex" ? "VERTEX_SHADER" : "FRAGMENT_SHADER";
    const std::string defines = feature
                                    ? "#define REFMAP_LEVEL 3\n#define REF_SAMPLE_COUNT 32\n"
                                    : "#define FXAA_GLSL_400 1\n"
                                      "#define FXAA_NO_DEPTH_WRITE 1\n"
                                      "#define FXAA_QUALITY__PRESET " +
                                          toString(variant.preset) + "\n";
    return "#extension GL_ARB_shading_language_420pack : enable\n"
           "#define " + toString(stageDefine) + " 1\n"
           "#define GBUFFER_FLAG_SKIP_ATMOS 0.0\n"
           "#define GBUFFER_FLAG_HAS_ATMOS 0.34\n"
           "#define GBUFFER_FLAG_HAS_PBR 0.67\n"
           "#define GBUFFER_FLAG_HAS_HDRI 1.0\n"
           "#define GET_GBUFFER_FLAG(data, flag) (abs((data) - (flag)) < 0.1)\n" +
           defines +
           "struct GBufferInfo { vec4 albedo; vec4 specular; vec3 normal; "
           "vec4 emissive; float gbufferFlag; float envIntensity; };\n";
}

std::string assembleWrapper(std::string source,
                            std::string_view preambleText,
                            std::string_view label)
{
    constexpr std::string_view marker = "[EXTRA_CODE_HERE]";
    const std::size_t markerCount = countSubstring(source, marker);
    require(markerCount <= 1, "source has more than one EXTRA_CODE_HERE marker");
    const std::string header = "#version 400 core\n";
    const std::string sourceMarker = "// source object: " + toString(label) + "\n";
    if (markerCount == 0)
    {
        return header + toString(preambleText) + sourceMarker + source;
    }

    const std::size_t markerOffset = source.find(marker);
    const std::size_t lineStart = source.rfind('\n', markerOffset);
    const std::size_t sourcePrefixEnd =
        lineStart == std::string::npos ? 0 : lineStart + 1;
    const std::size_t lineEnd = source.find('\n', markerOffset);
    require(lineEnd != std::string::npos,
            "EXTRA_CODE_HERE marker must occupy a terminated source line");
    const std::string before = source.substr(0, sourcePrefixEnd);
    const std::string after = source.substr(lineEnd + 1);
    return header + sourceMarker + before + toString(preambleText) + after;
}

std::string deleteGeneratorExtension(std::string wrapper,
                                     const std::filesystem::path& wrapperPath)
{
    constexpr std::string_view generatedExtension =
        "#extension GL_ARB_shading_language_420pack : enable\n";
    const std::size_t position = wrapper.find(generatedExtension);
    require(position != std::string::npos,
            "wrapper lacks its generator-owned 420pack extension: " +
                wrapperPath.string());
    require(wrapper.find(generatedExtension, position + generatedExtension.size()) ==
                std::string::npos,
            "wrapper has more than one 420pack extension: " + wrapperPath.string());
    wrapper.erase(position, generatedExtension.size());
    return wrapper;
}

void requireExactBytes(std::string_view actual,
                       std::string_view expected,
                       const std::filesystem::path& path)
{
    if (actual == expected)
    {
        return;
    }
    const std::size_t common = std::min(actual.size(), expected.size());
    std::size_t offset = 0;
    while (offset < common && actual[offset] == expected[offset])
    {
        ++offset;
    }
    fail("wrapper source mismatch at byte " + std::to_string(offset) + " in " +
         path.string() + " (actual=" + std::to_string(actual.size()) +
         ", expected=" + std::to_string(expected.size()) + ")");
}

void verifyObjectDirectory(const std::filesystem::path& directory,
                           const ObjectContract* objects,
                           std::size_t objectCount)
{
    std::vector<std::string> actual;
    for (const std::filesystem::directory_entry& entry :
         std::filesystem::directory_iterator(directory))
    {
        require(entry.is_regular_file(), "unexpected non-file shader object: " +
                                         entry.path().string());
        actual.push_back(entry.path().filename().string());
    }
    std::sort(actual.begin(), actual.end());
    require(actual.size() == objectCount,
            "unexpected shader object count in " + directory.string());
    for (std::size_t index = 0; index < objectCount; ++index)
    {
        require(actual[index] == objects[index].filename,
                "shader object ordinal/name mismatch in " + directory.string());
    }
}

struct GLSources
{
    std::vector<std::string> vertex;
    std::vector<std::string> fragment;
};

void verifyObject(const Options& options,
                  const Variant& variant,
                  const ObjectContract& object,
                  GLSources& sources)
{
    const std::filesystem::path wrapperPath = options.artifactRoot /
                                              toString(variant.id) / "objects" /
                                              toString(object.stage) /
                                              toString(object.filename);
    const std::string pinned =
        readFile(options.oracleWorktree / std::filesystem::path(toString(object.sourceLabel)));
    const std::string approved = approvedCurrentSource(object.sourceLabel, pinned);
    const std::string wrapper = readFile(wrapperPath);
    const std::string expected =
        assembleWrapper(approved, preamble(object.stage, object.feature, variant),
                        object.sourceLabel);
    requireExactBytes(wrapper, expected, wrapperPath);

    // The GL oracle runs the pinned bodies, preserving the historic depth write.
    // The sole adapter is deleting one generator-owned extension per object.
    const std::string oracleWrapper = deleteGeneratorExtension(
        assembleWrapper(pinned, preamble(object.stage, object.feature, variant),
                        object.sourceLabel),
        wrapperPath);
    if (object.stage == "vertex")
    {
        sources.vertex.push_back(oracleWrapper);
    }
    else
    {
        sources.fragment.push_back(oracleWrapper);
    }
}

GLSources verifyArtifactVariant(const Options& options, const Variant& variant)
{
    const std::filesystem::path root = options.artifactRoot / toString(variant.id) /
                                       "objects";
    verifyObjectDirectory(root / "vertex", kVertexObjects.data(),
                          kVertexObjects.size());
    verifyObjectDirectory(root / "fragment", kFragmentObjects.data(),
                          kFragmentObjects.size());

    GLSources sources;
    sources.vertex.reserve(kVertexObjects.size());
    sources.fragment.reserve(kFragmentObjects.size());
    for (const ObjectContract& object : kVertexObjects)
    {
        verifyObject(options, variant, object, sources);
    }
    for (const ObjectContract& object : kFragmentObjects)
    {
        verifyObject(options, variant, object, sources);
    }
    require(sources.vertex.size() == kVertexObjects.size() &&
                sources.fragment.size() == kFragmentObjects.size(),
            "incomplete generated FXAA object set");
    return sources;
}

void verifyBindingDescriptors(const MetalProgramDescriptor& program,
                              const Variant& variant)
{
    require(program.vertexBindings.buffers.size() == 1 &&
                program.vertexBindings.textures.empty() &&
                program.vertexBindings.samplers.empty(),
            "FXAA vertex binding contract changed for " + toString(variant.id));
    const auto& vertexBuffer = program.vertexBindings.buffers[0];
    require(vertexBuffer.name == "FirestormVertexUniforms" &&
                vertexBuffer.index == 24 && vertexBuffer.access == MetalResourceAccess::read_only &&
                vertexBuffer.size == 16 && vertexBuffer.alignment == 8 &&
                vertexBuffer.layoutSha256 ==
                    "3b79444d258e658c2244b9f2f4afc9ce644457f9dc970f1359fa7f21059e66cd",
            "FXAA vertex uniform binding changed for " + toString(variant.id));

    require(program.fragmentBindings.buffers.size() == 1 &&
                program.fragmentBindings.textures.size() == 1 &&
                program.fragmentBindings.samplers.size() == 1,
            "FXAA fragment binding count changed for " + toString(variant.id));
    const auto& fragmentBuffer = program.fragmentBindings.buffers[0];
    require(fragmentBuffer.name == "FirestormFragmentUniforms" &&
                fragmentBuffer.index == 24 &&
                fragmentBuffer.access == MetalResourceAccess::read_only &&
                fragmentBuffer.size == 496 && fragmentBuffer.alignment == 16 &&
                fragmentBuffer.layoutSha256 ==
                    "6e7b3a277cc79324f09c6ce60eb06d037bd5196d6eb55d46fc02411a59df6447",
            "FXAA fragment uniform binding changed for " + toString(variant.id));
    const auto& texture = program.fragmentBindings.textures[0];
    require(texture.name == "diffuseMap" && texture.index == 0 &&
                texture.access == MetalResourceAccess::read_only &&
                texture.type == MetalTextureType::texture_2d &&
                texture.dataType == MetalTextureDataType::float32 &&
                texture.arrayLength == 1 && !texture.depth,
            "FXAA diffuse texture binding changed for " + toString(variant.id));
    const auto& sampler = program.fragmentBindings.samplers[0];
    require(sampler.name == "diffuseMap" && sampler.index == 0,
            "FXAA diffuse sampler binding changed for " + toString(variant.id));
}

void verifyDescriptor(const MetalProgramDescriptor& program,
                      const Variant& variant)
{
    require(program.name == variant.id && program.family == "SMAA or FXAA" &&
                program.sourceSymbol == "gFXAAProgram" &&
                program.sourceIndex.has_value() &&
                *program.sourceIndex == variant.sourceIndex &&
                program.shaderClass == 3,
            "FXAA catalog selection changed for " + toString(variant.id));
    require(program.booleanSettings.empty() && program.integerSettings.size() == 2 &&
                program.integerSettings[0].name == "RenderFSAASamples" &&
                program.integerSettings[0].value ==
                    static_cast<std::int32_t>(variant.sourceIndex) &&
                program.integerSettings[1].name == "RenderFSAAType" &&
                program.integerSettings[1].value == 1,
            "FXAA catalog quality settings changed for " + toString(variant.id));
    require(program.vertexFunction == toString(variant.id) + "_vertex" &&
                program.fragmentFunction == toString(variant.id) + "_fragment" &&
                program.reflectionSha256 == variant.reflectionSha256,
            "FXAA function/reflection contract changed for " + toString(variant.id));
    require(program.colorFormats.size() == 1 &&
                program.colorFormats[0] == PixelFormat::rgba8_unorm &&
                !program.depthFormat.has_value() && program.sampleCount == 1,
            "FXAA target-format contract changed for " + toString(variant.id));
    require(program.vertexAttributes.size() == 1 && program.vertexLayouts.size() == 1,
            "FXAA vertex layout count changed for " + toString(variant.id));
    const auto& attribute = program.vertexAttributes[0];
    require(attribute.name == "position" && attribute.location == 0 &&
                attribute.bufferIndex == 16 &&
                attribute.format == MetalVertexFormat::float32x3 && attribute.offset == 0,
            "FXAA position attribute changed for " + toString(variant.id));
    const auto& layout = program.vertexLayouts[0];
    require(layout.bufferIndex == 16 && layout.stride == sizeof(Vertex) &&
                layout.stepFunction == MetalVertexStepFunction::per_vertex,
            "FXAA position layout changed for " + toString(variant.id));
    verifyBindingDescriptors(program, variant);
}

std::array<const MetalProgramDescriptor*, kVariants.size()> verifyCatalog(
    const MetalProgramLibrary& library)
{
    std::array<const MetalProgramDescriptor*, kVariants.size()> result{};
    std::size_t matchingDescriptors = 0;
    for (const MetalProgramDescriptor& descriptor : declaredMetalPrograms())
    {
        if (descriptor.sourceSymbol == "gFXAAProgram")
        {
            ++matchingDescriptors;
        }
    }
    require(matchingDescriptors == kVariants.size(),
            "catalog does not contain exactly four FXAA array descriptors");
    for (std::size_t index = 0; index < kVariants.size(); ++index)
    {
        const Variant& variant = kVariants[index];
        const MetalProgramDescriptor* descriptor =
            library.program("gFXAAProgram", variant.sourceIndex, 3);
        require(descriptor != nullptr,
                "catalog cannot select FXAA ordinal " +
                    std::to_string(variant.sourceIndex));
        verifyDescriptor(*descriptor, variant);
        result[index] = descriptor;
    }
    require(library.program("gFXAAProgram", std::uint16_t{4}, 3) == nullptr,
            "catalog unexpectedly has a fifth FXAA array descriptor");
    return result;
}

void checkGL(const char* operation)
{
    const GLenum error = glGetError();
    if (error != GL_NO_ERROR)
    {
        std::ostringstream message;
        message << "OpenGL error 0x" << std::hex << error << std::dec << " after "
                << operation;
        fail(message.str());
    }
}

std::string glInfoString(GLenum name)
{
    const GLubyte* value = glGetString(name);
    return value == nullptr ? "<unavailable>" :
                              std::string(reinterpret_cast<const char*>(value));
}

CGLContext makeCGLContext()
{
    const CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile,
        static_cast<CGLPixelFormatAttribute>(kCGLOGLPVersion_3_2_Core),
        kCGLPFAAccelerated,
        kCGLPFAColorSize,
        static_cast<CGLPixelFormatAttribute>(24),
        kCGLPFAAlphaSize,
        static_cast<CGLPixelFormatAttribute>(8),
        kCGLPFADepthSize,
        static_cast<CGLPixelFormatAttribute>(24),
        static_cast<CGLPixelFormatAttribute>(0),
    };
    CGLPixelFormatObj pixelFormat = nullptr;
    GLint formatCount = 0;
    const CGLError chooseError =
        CGLChoosePixelFormat(attributes, &pixelFormat, &formatCount);
    require(chooseError == kCGLNoError && pixelFormat != nullptr,
            std::string("CGLChoosePixelFormat failed: ") + CGLErrorString(chooseError));
    CGLContext context;
    const CGLError createError = CGLCreateContext(pixelFormat, nullptr, &context.context);
    CGLReleasePixelFormat(pixelFormat);
    require(createError == kCGLNoError && context.context != nullptr,
            std::string("CGLCreateContext failed: ") + CGLErrorString(createError));
    const CGLError currentError = CGLSetCurrentContext(context.context);
    require(currentError == kCGLNoError,
            std::string("CGLSetCurrentContext failed: ") + CGLErrorString(currentError));
    const std::string vendorText = glInfoString(GL_VENDOR);
    const std::string rendererText = glInfoString(GL_RENDERER);
    const std::string versionText = glInfoString(GL_VERSION);
    std::cout << "FXAA semantic gate CGL: vendor=\"" << vendorText
              << "\" renderer=\"" << rendererText << "\" version=\""
              << versionText << "\"\n";
    require(versionText != "<unavailable>", "CGL did not report an OpenGL version");
    require(versionText.rfind("4.1", 0) == 0,
            "FXAA oracle requires CGL OpenGL 4.1, found " + versionText);
    return context;
}

GLsizei checkedGLSize(std::size_t value, const char* description)
{
    require(value <= static_cast<std::size_t>(std::numeric_limits<GLsizei>::max()),
            std::string("value exceeds GLsizei: ") + description);
    return static_cast<GLsizei>(value);
}

std::string shaderLog(GLuint shader)
{
    GLint length = 0;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length);
    if (length <= 1)
    {
        return {};
    }
    std::string log(static_cast<std::size_t>(length), '\0');
    glGetShaderInfoLog(shader, length, nullptr, log.data());
    return trimTrailingLineEndings(log);
}

GLuint compileGLShader(GLenum stage,
                       const std::string& source,
                       std::string_view label)
{
    const GLuint shader = glCreateShader(stage);
    require(shader != 0, "glCreateShader failed for " + toString(label));
    const GLchar* sourcePointer = source.c_str();
    const GLint sourceLength =
        static_cast<GLint>(checkedGLSize(source.size(), "shader source"));
    glShaderSource(shader, 1, &sourcePointer, &sourceLength);
    glCompileShader(shader);
    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    const std::string log = shaderLog(shader);
    if (compiled != GL_TRUE)
    {
        glDeleteShader(shader);
        fail("CGL compile failed for " + toString(label) + ": " + log);
    }
    return shader;
}

std::string programLog(GLuint program)
{
    GLint length = 0;
    glGetProgramiv(program, GL_INFO_LOG_LENGTH, &length);
    if (length <= 1)
    {
        return {};
    }
    std::string log(static_cast<std::size_t>(length), '\0');
    glGetProgramInfoLog(program, length, nullptr, log.data());
    return trimTrailingLineEndings(log);
}

GLProgram linkGLProgram(const GLSources& sources, const Variant& variant)
{
    const GLuint program = glCreateProgram();
    require(program != 0, "glCreateProgram failed for " + toString(variant.id));
    std::vector<GLuint> shaders;
    shaders.reserve(sources.vertex.size() + sources.fragment.size());
    try
    {
        for (std::size_t index = 0; index < sources.vertex.size(); ++index)
        {
            shaders.push_back(compileGLShader(GL_VERTEX_SHADER, sources.vertex[index],
                                               kVertexObjects[index].sourceLabel));
            glAttachShader(program, shaders.back());
        }
        for (std::size_t index = 0; index < sources.fragment.size(); ++index)
        {
            shaders.push_back(compileGLShader(GL_FRAGMENT_SHADER, sources.fragment[index],
                                               kFragmentObjects[index].sourceLabel));
            glAttachShader(program, shaders.back());
        }
        glBindAttribLocation(program, 0, "position");
        glBindFragDataLocation(program, 0, "frag_color");
        glLinkProgram(program);
        GLint linked = GL_FALSE;
        glGetProgramiv(program, GL_LINK_STATUS, &linked);
        const std::string log = programLog(program);
        if (linked != GL_TRUE)
        {
            fail("CGL link failed for " + toString(variant.id) + ": " + log);
        }
    }
    catch (...)
    {
        for (const GLuint shader : shaders)
        {
            glDetachShader(program, shader);
            glDeleteShader(shader);
        }
        glDeleteProgram(program);
        throw;
    }
    for (const GLuint shader : shaders)
    {
        glDetachShader(program, shader);
        glDeleteShader(shader);
    }
    checkGL("linking pinned FXAA objects");
    GLProgram result;
    result.program = program;
    return result;
}

GLState makeGLState(const std::vector<std::uint8_t>& glSourceRows,
                    const std::vector<float>& glSourceDepthRows)
{
    require(glSourceRows.size() == kImageBytes, "unexpected color chart size");
    require(glSourceDepthRows.size() == static_cast<std::size_t>(kWidth) *
                                             static_cast<std::size_t>(kHeight),
            "unexpected depth chart size");
    GLState state;
    glGenVertexArrays(1, &state.vao);
    glBindVertexArray(state.vao);
    glGenBuffers(1, &state.vertexBuffer);
    glBindBuffer(GL_ARRAY_BUFFER, state.vertexBuffer);
    constexpr std::array<float, 9> positions{{
        -1.0F, -1.0F, 0.0F,
        3.0F, -1.0F, 0.0F,
        -1.0F, 3.0F, 0.0F,
    }};
    glBufferData(GL_ARRAY_BUFFER,
                 static_cast<GLsizeiptr>(positions.size() * sizeof(float)),
                 positions.data(), GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,
                          static_cast<GLsizei>(3 * sizeof(float)), nullptr);

    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glGenTextures(1, &state.inputTexture);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, state.inputTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_MIRRORED_REPEAT);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_MIRRORED_REPEAT);
    glTexImage2D(GL_TEXTURE_2D, 0, static_cast<GLint>(GL_RGBA8), kWidth, kHeight,
                 0, GL_RGBA, GL_UNSIGNED_BYTE, glSourceRows.data());

    glGenTextures(1, &state.depthInputTexture);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, state.depthInputTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_MIRRORED_REPEAT);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_MIRRORED_REPEAT);
    glTexImage2D(GL_TEXTURE_2D, 0, static_cast<GLint>(GL_R32F), kWidth, kHeight,
                 0, GL_RED, GL_FLOAT, glSourceDepthRows.data());

    glGenTextures(1, &state.outputTexture);
    glBindTexture(GL_TEXTURE_2D, state.outputTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, static_cast<GLint>(GL_RGBA8), kWidth, kHeight,
                 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);

    glGenTextures(1, &state.outputDepthTexture);
    glBindTexture(GL_TEXTURE_2D, state.outputDepthTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, static_cast<GLint>(GL_DEPTH_COMPONENT32F),
                 kWidth, kHeight, 0, GL_DEPTH_COMPONENT, GL_FLOAT, nullptr);

    glGenFramebuffers(1, &state.framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, state.framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           state.outputTexture, 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D,
                           state.outputDepthTexture, 0);
    constexpr GLenum drawBuffers[] = {GL_COLOR_ATTACHMENT0};
    glDrawBuffers(1, drawBuffers);
    require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
            "FXAA CGL framebuffer is incomplete");
    checkGL("creating FXAA CGL targets");
    return state;
}

GLint requireUniform(GLuint program, const char* name)
{
    const GLint location = glGetUniformLocation(program, name);
    require(location >= 0, std::string("CGL FXAA program lacks uniform ") + name);
    return location;
}

GLRenderResult renderGL(const GLState& state,
                        const GLProgram& program,
                        bool cullBack = false,
                        GLenum frontFace = GL_CCW)
{
    glBindFramebuffer(GL_FRAMEBUFFER, state.framebuffer);
    glViewport(0, 0, kWidth, kHeight);
    glDisable(GL_BLEND);
    glDisable(GL_DITHER);
    glDisable(GL_MULTISAMPLE);
    glDisable(GL_FRAMEBUFFER_SRGB);
    if (cullBack)
    {
        glEnable(GL_CULL_FACE);
        glCullFace(GL_BACK);
    }
    else
    {
        glDisable(GL_CULL_FACE); // FXAA itself is intentionally cull-none.
    }
    glEnable(GL_DEPTH_TEST);
    glDepthMask(GL_TRUE);
    glDepthFunc(GL_ALWAYS);
    glFrontFace(frontFace);
    glClearColor(1.0F, 0.0F, 1.0F, 1.0F);
    glClearDepth(0.0);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    glUseProgram(program.program);
    glUniform1i(requireUniform(program.program, "diffuseMap"), 0);
    glUniform1i(requireUniform(program.program, "depthMap"), 1);
    glUniform2f(requireUniform(program.program, "tc_scale"), 1.0F, 1.0F);
    const GLint screenRes = glGetUniformLocation(program.program, "screen_res");
    if (screenRes >= 0)
    {
        glUniform2f(screenRes, static_cast<float>(kWidth), static_cast<float>(kHeight));
    }
    glUniform2f(requireUniform(program.program, "rcp_screen_res"),
                1.0F / static_cast<float>(kWidth),
                1.0F / static_cast<float>(kHeight));
    glUniform4f(requireUniform(program.program, "rcp_frame_opt"),
                -0.5F / static_cast<float>(kWidth),
                -0.5F / static_cast<float>(kHeight),
                0.5F / static_cast<float>(kWidth),
                0.5F / static_cast<float>(kHeight));
    glUniform4f(requireUniform(program.program, "rcp_frame_opt2"),
                -2.0F / static_cast<float>(kWidth),
                -2.0F / static_cast<float>(kHeight),
                2.0F / static_cast<float>(kWidth),
                2.0F / static_cast<float>(kHeight));
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, state.inputTexture);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, state.depthInputTexture);
    glBindVertexArray(state.vao);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glFinish();
    checkGL("drawing pinned FXAA");

    GLRenderResult result;
    result.color.resize(kImageBytes);
    result.depth.resize(static_cast<std::size_t>(kWidth) *
                        static_cast<std::size_t>(kHeight));
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadBuffer(GL_COLOR_ATTACHMENT0);
    glReadPixels(0, 0, kWidth, kHeight, GL_RGBA, GL_UNSIGNED_BYTE,
                 result.color.data());
    glReadPixels(0, 0, kWidth, kHeight, GL_DEPTH_COMPONENT, GL_FLOAT,
                 result.depth.data());
    checkGL("reading pinned FXAA output");
    // CGL exposes framebuffer rows bottom-up.  Normalize its visual result;
    // Metal keeps the same declared GL-source input rows and raw readback.
    result.color = flipRows(result.color,
                            static_cast<std::size_t>(kWidth) * kChannels);
    result.depth = flipRows(result.depth, static_cast<std::size_t>(kWidth));
    return result;
}

void verifyDepthWrite(const std::vector<float>& actual,
                      const std::vector<float>& expected,
                      const Variant& variant)
{
    require(actual.size() == expected.size(), "FXAA depth result size changed");
    constexpr float tolerance = 0.00001F;
    for (std::size_t index = 0; index < actual.size(); ++index)
    {
        if (std::fabs(actual[index] - expected[index]) > tolerance)
        {
            const std::size_t x = index % static_cast<std::size_t>(kWidth);
            const std::size_t y = index / static_cast<std::size_t>(kWidth);
            fail("pinned FXAA depth write mismatch for " + toString(variant.id) +
                 " at (" + std::to_string(x) + "," + std::to_string(y) +
                 "): expected " + std::to_string(expected[index]) +
                 ", got " + std::to_string(actual[index]));
        }
    }
}

NSString* toNSString(std::string_view value)
{
    return [[NSString alloc] initWithBytes:value.data()
                                    length:static_cast<NSUInteger>(value.size())
                                  encoding:NSUTF8StringEncoding];
}

std::string nsError(NSError* error)
{
    if (error == nil || error.localizedDescription.UTF8String == nullptr)
    {
        return "unknown Metal error";
    }
    return error.localizedDescription.UTF8String;
}

MTLVertexDescriptor* makeMetalVertexDescriptor()
{
    MTLVertexDescriptor* descriptor = [MTLVertexDescriptor vertexDescriptor];
    descriptor.attributes[0].format = MTLVertexFormatFloat3;
    descriptor.attributes[0].offset = 0;
    descriptor.attributes[0].bufferIndex = 16;
    descriptor.layouts[16].stride = sizeof(Vertex);
    descriptor.layouts[16].stepFunction = MTLVertexStepFunctionPerVertex;
    descriptor.layouts[16].stepRate = 1;
    return descriptor;
}

id<MTLTexture> makeMetalTexture(id<MTLDevice> device,
                                 MTLPixelFormat format,
                                 MTLTextureUsage usage,
                                 const std::vector<std::uint8_t>* data)
{
    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                             width:static_cast<NSUInteger>(kWidth)
                                                            height:static_cast<NSUInteger>(kHeight)
                                                         mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = usage;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    require(texture != nil, "cannot allocate Metal FXAA texture");
    if (data != nullptr)
    {
        require(data->size() == kImageBytes, "unexpected Metal input image size");
        [texture replaceRegion:MTLRegionMake2D(0, 0,
                                               static_cast<NSUInteger>(kWidth),
                                               static_cast<NSUInteger>(kHeight))
                    mipmapLevel:0
                      withBytes:data->data()
                    bytesPerRow:static_cast<NSUInteger>(kWidth *
                                                         static_cast<int>(kChannels))];
    }
    return texture;
}

MetalRenderResult renderMetal(id<MTLDevice> device,
                              id<MTLLibrary> library,
                              id<MTLCommandQueue> queue,
                              const MetalProgramDescriptor& program,
                              const std::vector<std::uint8_t>& glSourceRows,
                              MTLCullMode cullMode = MTLCullModeNone,
                              MTLWinding winding = MTLWindingCounterClockwise)
{
    NSString* vertexName = toNSString(program.vertexFunction);
    NSString* fragmentName = toNSString(program.fragmentFunction);
    require(vertexName != nil && fragmentName != nil,
            "FXAA Metal function name is not UTF-8");
    id<MTLFunction> vertexFunction = [library newFunctionWithName:vertexName];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:fragmentName];
    require(vertexFunction != nil && fragmentFunction != nil,
            "combined metallib lacks FXAA functions for " + toString(program.name));

    MTLRenderPipelineDescriptor* pipelineDescriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    pipelineDescriptor.vertexDescriptor = makeMetalVertexDescriptor();
    pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    NSError* error = nil;
    id<MTLRenderPipelineState> pipeline =
        [device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    require(pipeline != nil,
            "cannot create FXAA Metal pipeline for " + toString(program.name) +
                ": " + nsError(error));

    id<MTLTexture> input = makeMetalTexture(device, MTLPixelFormatRGBA8Unorm,
                                             MTLTextureUsageShaderRead, &glSourceRows);
    id<MTLTexture> output = makeMetalTexture(device, MTLPixelFormatRGBA8Unorm,
                                              MTLTextureUsageRenderTarget, nullptr);
    MTLSamplerDescriptor* samplerDescriptor = [[MTLSamplerDescriptor alloc] init];
    samplerDescriptor.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
    samplerDescriptor.mipFilter = MTLSamplerMipFilterNotMipmapped;
    samplerDescriptor.sAddressMode = MTLSamplerAddressModeMirrorRepeat;
    samplerDescriptor.tAddressMode = MTLSamplerAddressModeMirrorRepeat;
    samplerDescriptor.normalizedCoordinates = YES;
    id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:samplerDescriptor];
    require(sampler != nil, "cannot create Metal FXAA mirror-repeat sampler");

    constexpr std::array<Vertex, 3> vertices{{
        {-1.0F, -1.0F, 0.0F, 0.0F},
        {3.0F, -1.0F, 0.0F, 0.0F},
        {-1.0F, 3.0F, 0.0F, 0.0F},
    }};
    static_assert(sizeof(Vertex) == 16, "FXAA generated vertex stride changed");
    static_assert(sizeof(VertexUniforms) == 16,
                  "FXAA generated vertex uniform layout changed");
    const VertexUniforms vertexUniforms{{1.0F, 1.0F},
                                        {static_cast<float>(kWidth),
                                         static_cast<float>(kHeight)}};
    std::array<std::uint8_t, 496> fragmentUniforms{};
    const std::array<float, 2> reciprocalResolution{{
        1.0F / static_cast<float>(kWidth),
        1.0F / static_cast<float>(kHeight),
    }};
    const std::array<float, 4> frameOpt{{
        -0.5F / static_cast<float>(kWidth),
        -0.5F / static_cast<float>(kHeight),
        0.5F / static_cast<float>(kWidth),
        0.5F / static_cast<float>(kHeight),
    }};
    const std::array<float, 4> frameOpt2{{
        -2.0F / static_cast<float>(kWidth),
        -2.0F / static_cast<float>(kHeight),
        2.0F / static_cast<float>(kWidth),
        2.0F / static_cast<float>(kHeight),
    }};
    std::memcpy(fragmentUniforms.data(), reciprocalResolution.data(),
                sizeof(reciprocalResolution));
    std::memcpy(fragmentUniforms.data() + 16, frameOpt.data(), sizeof(frameOpt));
    std::memcpy(fragmentUniforms.data() + 32, frameOpt2.data(), sizeof(frameOpt2));

    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = output;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 0.0, 1.0, 1.0);

    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    require(commandBuffer != nil, "cannot create Metal FXAA command buffer");
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:pass];
    require(encoder != nil, "cannot create Metal FXAA render encoder");
    [encoder setRenderPipelineState:pipeline];
    [encoder setCullMode:cullMode];
    [encoder setFrontFacingWinding:winding];
    [encoder setVertexBytes:vertices.data()
                     length:static_cast<NSUInteger>(vertices.size() * sizeof(Vertex))
                    atIndex:16];
    [encoder setVertexBytes:&vertexUniforms
                     length:sizeof(vertexUniforms)
                    atIndex:24];
    [encoder setFragmentBytes:fragmentUniforms.data()
                       length:static_cast<NSUInteger>(fragmentUniforms.size())
                      atIndex:24];
    [encoder setFragmentTexture:input atIndex:0];
    [encoder setFragmentSamplerState:sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    require(commandBuffer.status != MTLCommandBufferStatusError,
            "Metal FXAA command failed: " + nsError(commandBuffer.error));

    MetalRenderResult result;
    result.color.resize(kImageBytes);
    // This test declares GL-source texture row order for both APIs.  Metal
    // readback remains raw: it is not a claim about a production resource-origin policy.
    [output getBytes:result.color.data()
          bytesPerRow:static_cast<NSUInteger>(kWidth * static_cast<int>(kChannels))
           fromRegion:MTLRegionMake2D(0, 0, static_cast<NSUInteger>(kWidth),
                                      static_cast<NSUInteger>(kHeight))
          mipmapLevel:0];
    return result;
}

std::size_t changedPixelCount(const std::vector<std::uint8_t>& input,
                              const std::vector<std::uint8_t>& output)
{
    require(input.size() == output.size() && input.size() == kImageBytes,
            "invalid FXAA image comparison size");
    std::size_t changed = 0;
    for (std::size_t offset = 0; offset < input.size(); offset += kPixelBytes)
    {
        bool different = false;
        for (std::size_t channel = 0; channel < kChannels; ++channel)
        {
            if (input[offset + channel] != output[offset + channel])
            {
                different = true;
            }
        }
        changed += different ? 1U : 0U;
    }
    return changed;
}

void requireCornerAnchors(const std::vector<std::uint8_t>& pixels,
                          const std::string& label)
{
    require(pixels.size() == kImageBytes, label + " image size mismatch");
    struct Corner
    {
        int x;
        int y;
        std::array<std::uint8_t, 4> rgba;
    };
    constexpr std::array<Corner, 4> corners{{
        {1, 1, {255, 0, 0, 76}},
        {126, 1, {0, 255, 0, 150}},
        {1, 62, {0, 0, 255, 37}},
        {126, 62, {255, 255, 0, 226}},
    }};
    for (const Corner& corner : corners)
    {
        const std::size_t offset = pixelOffset(corner.x, corner.y);
        for (std::size_t channel = 0; channel < kChannels; ++channel)
        {
            if (pixels[offset + channel] != corner.rgba[channel])
            {
                fail(label + " corner anchor mismatch at (" +
                     std::to_string(corner.x) + "," + std::to_string(corner.y) +
                     ") channel " + std::to_string(channel) + ": expected " +
                     std::to_string(corner.rgba[channel]) + ", got " +
                     std::to_string(pixels[offset + channel]));
            }
        }
    }
}

void compareExact(const std::vector<std::uint8_t>& expected,
                  const std::vector<std::uint8_t>& actual,
                  const std::string& description)
{
    require(expected.size() == actual.size(), description + " image size mismatch");
    for (std::size_t offset = 0; offset < expected.size(); ++offset)
    {
        if (expected[offset] != actual[offset])
        {
            const std::size_t pixel = offset / kPixelBytes;
            const std::size_t channel = offset % kPixelBytes;
            fail(description + " differs at (" +
                 std::to_string(pixel % static_cast<std::size_t>(kWidth)) + "," +
                 std::to_string(pixel / static_cast<std::size_t>(kWidth)) +
                 ") channel " + std::to_string(channel) + ": expected " +
                 std::to_string(expected[offset]) + ", got " +
                 std::to_string(actual[offset]));
        }
    }
}

void compareWithinOne(const std::vector<std::uint8_t>& gl,
                      const std::vector<std::uint8_t>& metal,
                      const Variant& variant)
{
    require(gl.size() == metal.size() && gl.size() == kImageBytes,
            "invalid GL/Metal FXAA image comparison size");
    std::size_t mismatches = 0;
    std::uint8_t maximumDifference = 0;
    std::ostringstream examples;
    for (std::size_t offset = 0; offset < gl.size(); ++offset)
    {
        const int difference = std::abs(static_cast<int>(gl[offset]) -
                                        static_cast<int>(metal[offset]));
        maximumDifference = std::max(maximumDifference,
                                     static_cast<std::uint8_t>(difference));
        if (difference > static_cast<int>(kComparisonTolerance))
        {
            ++mismatches;
            if (mismatches <= 8)
            {
                const std::size_t pixel = offset / kPixelBytes;
                examples << " (" << pixel % static_cast<std::size_t>(kWidth) << ','
                         << pixel / static_cast<std::size_t>(kWidth) << ",c"
                         << offset % kPixelBytes << ": gl="
                         << static_cast<unsigned int>(gl[offset]) << ", metal="
                         << static_cast<unsigned int>(metal[offset]) << ')';
            }
        }
    }
    require(mismatches == 0,
            "FXAA GL/Metal mismatch for " + toString(variant.id) + ": " +
                std::to_string(mismatches) + " channels exceed +/-1 (max=" +
                std::to_string(maximumDifference) + ")" + examples.str());
}

void requireClearMagenta(const std::vector<std::uint8_t>& image,
                         const std::string& description)
{
    require(image.size() == kImageBytes, description + " image size mismatch");
    for (std::size_t offset = 0; offset < image.size(); offset += kPixelBytes)
    {
        if (image[offset] != 255 || image[offset + 1] != 0 ||
            image[offset + 2] != 255 || image[offset + 3] != 255)
        {
            const std::size_t pixel = offset / kPixelBytes;
            fail(description + " was not culled at (" +
                 std::to_string(pixel % static_cast<std::size_t>(kWidth)) + "," +
                 std::to_string(pixel / static_cast<std::size_t>(kWidth)) + ")");
        }
    }
}

} // namespace

int main(int argc, const char* argv[])
{
    @autoreleasepool
    {
        try
        {
            const Options options = parseOptions(argc, argv);
            std::cout << "FXAA semantic gate inputs: metallib=\""
                      << options.metallib.string() << "\" artifact-root=\""
                      << options.artifactRoot.string() << "\" oracle-worktree=\""
                      << options.oracleWorktree.string() << "\"\n";
            // Do this before reading either baseline source or generated wrappers.
            verifyOracleWorktree(options.oracleWorktree);
            verifyBaselineRuntimeContracts(options.oracleWorktree);

            CGLContext cgl = makeCGLContext();
            const std::vector<std::uint8_t> chart = makeChart();
            const std::vector<float> depthChart = makeDepthChart();
            // The source renderer uploads rows in GL texture order.  This is
            // a test-only input boundary, not a production resource-origin ABI.
            const std::vector<std::uint8_t> glSourceRows =
                flipRows(chart, static_cast<std::size_t>(kWidth) * kChannels);
            const std::vector<float> glSourceDepthRows =
                flipRows(depthChart, static_cast<std::size_t>(kWidth));
            GLState glState = makeGLState(glSourceRows, glSourceDepthRows);

            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            require(device != nil, "no default Metal device");
            NSString* deviceName = device.name;
            const char* deviceNameText = deviceName.UTF8String;
            std::cout << "FXAA semantic gate Metal: device=\""
                      << (deviceNameText == nullptr ? "<unavailable>" : deviceNameText)
                      << "\"\n";
            MetalProgramLibrary programLibrary((__bridge void*)device,
                                               options.metallib.string());
            require(programLibrary.valid(),
                    "cannot load the combined FXAA metallib: " +
                        programLibrary.error());
            const auto descriptors = verifyCatalog(programLibrary);
            id<MTLLibrary> library =
                (__bridge id<MTLLibrary>)programLibrary.nativeLibrary();
            require(library != nil, "combined FXAA metallib has no native library");
            id<MTLCommandQueue> queue = [device newCommandQueue];
            require(queue != nil, "cannot create Metal command queue");

            std::set<std::uint64_t> glDigests;
            std::set<std::uint64_t> metalDigests;
            for (std::size_t index = 0; index < kVariants.size(); ++index)
            {
                const Variant& variant = kVariants[index];
                const GLSources sources = verifyArtifactVariant(options, variant);
                const GLProgram glProgram = linkGLProgram(sources, variant);
                const GLRenderResult first = renderGL(glState, glProgram);
                verifyDepthWrite(first.depth, depthChart, variant);
                requireCornerAnchors(first.color,
                                     "canonical GL output for " + toString(variant.id));
                for (std::size_t repeat = 1; repeat < kGLRepeats; ++repeat)
                {
                    const GLRenderResult next = renderGL(glState, glProgram);
                    compareExact(first.color, next.color,
                                 "GL FXAA repeat " + std::to_string(repeat + 1) +
                                     " for " + toString(variant.id));
                }
                const std::size_t changed = changedPixelCount(chart, first.color);
                require(changed >= kMinimumChangedPixels,
                        "FXAA did not change enough designed chart pixels for " +
                            toString(variant.id) + ": " + std::to_string(changed));

                const MetalRenderResult metal =
                    renderMetal(device, library, queue, *descriptors[index], glSourceRows);
                requireCornerAnchors(metal.color,
                                     "canonical Metal output for " + toString(variant.id));
                compareWithinOne(first.color, metal.color, variant);
                if (index == 0)
                {
                    // The source full-screen triangle is CCW in CGL and Metal.
                    // FXAA itself remains cull-none above; this small probe
                    // records the direct front-face contract at this test boundary.
                    const GLRenderResult glCCWBack =
                        renderGL(glState, glProgram, true, GL_CCW);
                    compareExact(first.color, glCCWBack.color,
                                 "CGL source-CCW/back-cull FXAA probe");
                    const MetalRenderResult metalCCWBack =
                        renderMetal(device, library, queue, *descriptors[index], glSourceRows,
                                    MTLCullModeBack, MTLWindingCounterClockwise);
                    compareExact(metal.color, metalCCWBack.color,
                                 "Metal source-CCW/back-cull FXAA probe");
                    const MetalRenderResult metalCWBack =
                        renderMetal(device, library, queue, *descriptors[index], glSourceRows,
                                    MTLCullModeBack, MTLWindingClockwise);
                    requireClearMagenta(metalCWBack.color,
                                        "Metal unmapped-CW/back-cull FXAA probe");
                }
                const std::uint64_t glDigest = fnv1a64(first.color);
                const std::uint64_t metalDigest = fnv1a64(metal.color);
                glDigests.insert(glDigest);
                metalDigests.insert(metalDigest);
                std::cout << variant.id << " changed_pixels=" << changed
                          << " gl_fnv1a64=0x" << std::hex << glDigest
                          << " metal_fnv1a64=0x" << metalDigest << std::dec << '\n';
            }
            require(glDigests.size() == kVariants.size(),
                    "the four FXAA GL quality outputs are not distinct");
            require(metalDigests.size() == kVariants.size(),
                    "the four FXAA Metal quality outputs are not distinct");
            std::cout << "FXAA source-pinned CGL/Metal semantic gate: PASS\n";
            return EXIT_SUCCESS;
        }
        catch (const std::exception& error)
        {
            std::cerr << "FXAA source-pinned CGL/Metal semantic gate: FAIL: "
                      << error.what() << '\n';
        }
    }
    return EXIT_FAILURE;
}
