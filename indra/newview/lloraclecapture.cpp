/**
 * @file lloraclecapture.cpp
 * @brief Developer-only OpenGL oracle acquisition controller.
 *
 * $LicenseInfo:firstyear=2026&license=viewerlgpl$
 * Copyright (C) 2026, The Phoenix Firestorm Project, Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation;
 * version 2.1 of the License only.
 * $/LicenseInfo$
 */

#include "llviewerprecompiledheaders.h"

#include "lloraclecapture.h"

#include <algorithm>
#include <filesystem>
#include <limits>
#include <stdexcept>

namespace lloracle
{
CaptureSequence::CaptureSequence(U32 warmup_frames, U32 measurement_frames, U32 capture_frames)
:   mWarmupEnd(warmup_frames),
    mMeasurementEnd(mWarmupEnd + measurement_frames),
    mCaptureEnd(mMeasurementEnd + capture_frames)
{
    if (mMeasurementEnd < mWarmupEnd || mCaptureEnd < mMeasurementEnd)
    {
        throw std::overflow_error("oracle capture frame counts overflow");
    }
}

FramePhase CaptureSequence::phase() const
{
    if (mPresented < mWarmupEnd)
    {
        return FramePhase::WARMUP;
    }
    if (mPresented < mMeasurementEnd)
    {
        return FramePhase::MEASUREMENT;
    }
    if (mPresented < mCaptureEnd)
    {
        return FramePhase::CAPTURE;
    }
    return FramePhase::COMPLETE;
}

U64 CaptureSequence::frameSerial() const
{
    return mPresented + 1;
}

U64 CaptureSequence::presentedCount() const
{
    return mPresented;
}

void CaptureSequence::presented()
{
    if (!complete())
    {
        ++mPresented;
    }
}

bool CaptureSequence::complete() const
{
    return mPresented >= mCaptureEnd;
}

void flipRows(std::vector<U8>& bytes, std::size_t row_bytes, std::size_t height)
{
    if (height == 0 || row_bytes == 0 || row_bytes > std::numeric_limits<std::size_t>::max() / height ||
        bytes.size() != row_bytes * height)
    {
        throw std::invalid_argument("invalid oracle capture row layout");
    }

    std::vector<U8> row(row_bytes);
    for (std::size_t top = 0, bottom = height - 1; top < bottom; ++top, --bottom)
    {
        U8* top_row = bytes.data() + top * row_bytes;
        U8* bottom_row = bytes.data() + bottom * row_bytes;
        std::copy(top_row, top_row + row_bytes, row.begin());
        std::copy(bottom_row, bottom_row + row_bytes, top_row);
        std::copy(row.begin(), row.end(), bottom_row);
    }
}

bool isSafeRelativePath(const std::string& path)
{
    if (path.empty() || path.find('\\') != std::string::npos)
    {
        return false;
    }

    const std::filesystem::path candidate(path);
    if (candidate.is_absolute() || candidate.has_root_name() || candidate.has_root_directory())
    {
        return false;
    }

    for (const auto& component : candidate)
    {
        if (component.empty() || component == "." || component == "..")
        {
            return false;
        }
    }
    return candidate.generic_string() == path;
}

bool isSupportedMachineContractKind(std::string_view kind)
{
    // This hook can observe only settings and display state. Corpus-admissible
    // typed runtime state requires a future semantic fixture observer.
    return kind == "capture_self_test_v1";
}

bool isSupportedSelfTestWindowMode(std::string_view mode)
{
    // A self-test can observe window visibility and minimization, but it has
    // no dedicated-Space proof that would justify the corpus no-occlusion claim.
    return mode == "windowed_visible_not_minimized";
}

bool hasOwnedUnpublishedStaging(OutputPublicationState state)
{
    return state == OutputPublicationState::STAGING_OWNED;
}
}

#ifndef LL_TEST

#include "llapp.h"
#include "llappviewer.h"
#include "llcontrol.h"
#include "lldir.h"
#include "llfocusmgr.h"
#include "llgl.h"
#include "llglheaders.h"
#include "llglslshader.h"
#include "llimagegl.h"
#include "llimagepng.h"
#include "lleventapi.h"
#include "llevents.h"
#include "llmemory.h"
#include "llperfstats.h"
#include "llpointer.h"
#include "llrendertarget.h"
#include "llsdjson.h"
#include "llsys.h"
#include "lluuid.h"
#include "llversioninfo.h"
#include "llviewercontrol.h"
#include "llviewerwindow.h"
#include "llvertexbuffer.h"
#include "llwindow.h"

#include <boost/charconv.hpp>
#include <boost/json.hpp>
#include <openssl/evp.h>

#if LL_DARWIN
#include <ApplicationServices/ApplicationServices.h>
#include <OpenGL/OpenGL.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <sys/stdio.h>
#include <sys/sysctl.h>
#endif

#include <array>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <initializer_list>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <system_error>
#include <sys/stat.h>
#include <unistd.h>

#include "lloraclebuildidentity.h"

extern bool gShaderProfileFrame;

namespace
{
namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;

constexpr U32 ORACLE_WARMUP_FRAMES = 300;
constexpr U32 ORACLE_MEASUREMENT_FRAMES = 600;
constexpr U32 ORACLE_CAPTURE_FRAMES = 3;
constexpr std::size_t MAX_REQUEST_BYTES = 16 * 1024 * 1024;
constexpr std::size_t MAX_CAPTURE_BYTES = 256 * 1024 * 1024;

class CaptureError : public std::runtime_error
{
public:
    using std::runtime_error::runtime_error;
};

struct DigestContextDeleter
{
    void operator()(EVP_MD_CTX* context) const
    {
        EVP_MD_CTX_free(context);
    }
};

using DigestContext = std::unique_ptr<EVP_MD_CTX, DigestContextDeleter>;

std::string hexDigest(const unsigned char* digest, unsigned int length)
{
    std::ostringstream output;
    output << std::hex << std::setfill('0');
    for (unsigned int index = 0; index < length; ++index)
    {
        output << std::setw(2) << static_cast<unsigned int>(digest[index]);
    }
    return output.str();
}

std::string sha256(const U8* data, std::size_t size)
{
    DigestContext context(EVP_MD_CTX_new());
    if (!context || EVP_DigestInit_ex(context.get(), EVP_sha256(), nullptr) != 1 ||
        EVP_DigestUpdate(context.get(), data, size) != 1)
    {
        throw CaptureError("cannot initialize SHA-256");
    }

    std::array<unsigned char, EVP_MAX_MD_SIZE> digest{};
    unsigned int length = 0;
    if (EVP_DigestFinal_ex(context.get(), digest.data(), &length) != 1 || length != 32)
    {
        throw CaptureError("cannot finalize SHA-256");
    }
    return hexDigest(digest.data(), length);
}

std::string sha256(const std::vector<U8>& data)
{
    return sha256(data.data(), data.size());
}

std::vector<U8> readFile(const fs::path& path, std::size_t maximum_bytes)
{
    std::ifstream input(path, std::ios::binary);
    if (!input)
    {
        throw CaptureError("cannot open " + path.string());
    }

    input.seekg(0, std::ios::end);
    const std::streamoff length = input.tellg();
    if (length < 0 || static_cast<unsigned long long>(length) > maximum_bytes)
    {
        throw CaptureError("file exceeds its size contract: " + path.string());
    }
    input.seekg(0, std::ios::beg);

    std::vector<U8> bytes(static_cast<std::size_t>(length));
    if (!bytes.empty() && !input.read(reinterpret_cast<char*>(bytes.data()), length))
    {
        throw CaptureError("cannot read " + path.string());
    }
    return bytes;
}

bool isLowerHex(const std::string& value, std::size_t length)
{
    return value.size() == length && std::all_of(value.begin(), value.end(), [](char character)
    {
        return (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f');
    });
}

bool isUuid(const std::string& value)
{
    if (value.size() != 36)
    {
        return false;
    }
    for (std::size_t index = 0; index < value.size(); ++index)
    {
        if (index == 8 || index == 13 || index == 18 || index == 23)
        {
            if (value[index] != '-')
            {
                return false;
            }
        }
        else if (!((value[index] >= '0' && value[index] <= '9') ||
                   (value[index] >= 'a' && value[index] <= 'f')))
        {
            return false;
        }
    }
    return true;
}

const boost::json::object& requireObject(const boost::json::value& value, const std::string& field)
{
    if (!value.is_object())
    {
        throw CaptureError(field + " must be an object");
    }
    return value.as_object();
}

const boost::json::array& requireArray(const boost::json::value& value, const std::string& field)
{
    if (!value.is_array())
    {
        throw CaptureError(field + " must be an array");
    }
    return value.as_array();
}

const boost::json::value& requireField(const boost::json::object& object, const std::string& field)
{
    auto found = object.find(field);
    if (found == object.end())
    {
        throw CaptureError("missing request field " + field);
    }
    return found->value();
}

std::string requireString(const boost::json::object& object, const std::string& field)
{
    const auto& value = requireField(object, field);
    if (!value.is_string() || value.as_string().empty())
    {
        throw CaptureError(field + " must be a non-empty string");
    }
    return std::string(value.as_string());
}

S64 requireInteger(const boost::json::object& object, const std::string& field)
{
    const auto& value = requireField(object, field);
    if (!value.is_int64())
    {
        throw CaptureError(field + " must be an integer");
    }
    return value.as_int64();
}

double requireNumber(const boost::json::object& object, const std::string& field)
{
    const auto& value = requireField(object, field);
    double number = 0.0;
    if (value.is_double())
    {
        number = value.as_double();
    }
    else if (value.is_int64())
    {
        number = static_cast<double>(value.as_int64());
    }
    else if (value.is_uint64())
    {
        number = static_cast<double>(value.as_uint64());
    }
    else
    {
        throw CaptureError(field + " must be a number");
    }
    if (!std::isfinite(number))
    {
        throw CaptureError(field + " must be finite");
    }
    return number;
}

void requireExactKeys(
    const boost::json::object& object,
    std::initializer_list<const char*> expected,
    const std::string& field)
{
    std::set<std::string> expected_keys;
    for (const char* key : expected)
    {
        expected_keys.emplace(key);
    }

    std::set<std::string> actual_keys;
    for (const auto& member : object)
    {
        actual_keys.emplace(member.key());
    }
    if (actual_keys != expected_keys)
    {
        throw CaptureError(field + " fields do not match schema");
    }
}

std::string canonicalNumber(double value)
{
    std::array<char, 128> buffer{};
    auto result = boost::charconv::to_chars(
        buffer.data(), buffer.data() + buffer.size(), value, boost::charconv::chars_format::general);
    if (result.ec != std::errc())
    {
        throw CaptureError("cannot serialize a JSON number");
    }
    std::string encoded(buffer.data(), result.ptr);
    if (encoded.find_first_of(".eE") == std::string::npos)
    {
        encoded += ".0";
    }
    std::replace(encoded.begin(), encoded.end(), 'E', 'e');
    return encoded;
}

std::string canonicalJson(const boost::json::value& value)
{
    if (value.is_null())
    {
        return "null";
    }
    if (value.is_bool())
    {
        return value.as_bool() ? "true" : "false";
    }
    if (value.is_int64())
    {
        return std::to_string(value.as_int64());
    }
    if (value.is_uint64())
    {
        return std::to_string(value.as_uint64());
    }
    if (value.is_double())
    {
        return canonicalNumber(value.as_double());
    }
    if (value.is_string())
    {
        const auto& string = value.as_string();
        if (std::any_of(string.begin(), string.end(), [](unsigned char character) { return character >= 0x80; }))
        {
            throw CaptureError("oracle request canonical strings must be ASCII");
        }
        return boost::json::serialize(value);
    }
    if (value.is_array())
    {
        std::string encoded = "[";
        bool first = true;
        for (const auto& item : value.as_array())
        {
            if (!first)
            {
                encoded += ',';
            }
            first = false;
            encoded += canonicalJson(item);
        }
        encoded += ']';
        return encoded;
    }

    std::map<std::string, const boost::json::value*> sorted;
    for (const auto& member : value.as_object())
    {
        sorted.emplace(member.key(), &member.value());
    }
    std::string encoded = "{";
    bool first = true;
    for (const auto& [key, member] : sorted)
    {
        if (!first)
        {
            encoded += ',';
        }
        first = false;
        encoded += boost::json::serialize(boost::json::value(key));
        encoded += ':';
        encoded += canonicalJson(*member);
    }
    encoded += '}';
    return encoded;
}

std::string canonicalHash(const boost::json::value& value)
{
    const std::string encoded = canonicalJson(value);
    return sha256(reinterpret_cast<const U8*>(encoded.data()), encoded.size());
}

void writeDurable(const fs::path& path, const std::vector<U8>& bytes)
{
    const int descriptor = ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (descriptor < 0)
    {
        throw CaptureError("cannot create " + path.string() + ": " + std::strerror(errno));
    }

    std::size_t offset = 0;
    bool success = true;
    while (offset < bytes.size())
    {
        const ssize_t written = ::write(descriptor, bytes.data() + offset, bytes.size() - offset);
        if (written <= 0)
        {
            success = false;
            break;
        }
        offset += static_cast<std::size_t>(written);
    }
    if (success && ::fsync(descriptor) != 0)
    {
        success = false;
    }
    const int close_result = ::close(descriptor);
    if (!success || close_result != 0)
    {
        std::error_code ignored;
        fs::remove(path, ignored);
        throw CaptureError("cannot durably write " + path.string());
    }
}

void syncDirectory(const fs::path& path)
{
    const int descriptor = ::open(path.c_str(), O_RDONLY);
    if (descriptor < 0 || ::fsync(descriptor) != 0)
    {
        if (descriptor >= 0)
        {
            ::close(descriptor);
        }
        throw CaptureError("cannot synchronize directory " + path.string());
    }
    ::close(descriptor);
}

std::string sysctlString(const char* name)
{
#if LL_DARWIN
    std::size_t size = 0;
    if (::sysctlbyname(name, nullptr, &size, nullptr, 0) != 0 || size == 0)
    {
        return "unavailable";
    }
    std::vector<char> value(size);
    if (::sysctlbyname(name, value.data(), &size, nullptr, 0) != 0 || size == 0)
    {
        return "unavailable";
    }
    if (value[size - 1] == '\0')
    {
        --size;
    }
    return std::string(value.data(), size);
#else
    (void)name;
    return "unavailable";
#endif
}

std::string xcodeBuild()
{
    fs::path developer = "/Applications/Xcode.app/Contents/Developer";
    if (const char* configured = std::getenv("DEVELOPER_DIR"))
    {
        developer = configured;
    }
    const fs::path version_path = developer.parent_path() / "version.plist";
    try
    {
        const auto encoded = readFile(version_path, 1024 * 1024);
        const std::string plist(encoded.begin(), encoded.end());
        auto valueAfter = [&plist](const std::string& key) -> std::string
        {
            const std::string marker = "<key>" + key + "</key>";
            std::size_t position = plist.find(marker);
            if (position == std::string::npos)
            {
                return {};
            }
            position = plist.find("<string>", position + marker.size());
            if (position == std::string::npos)
            {
                return {};
            }
            position += 8;
            const std::size_t end = plist.find("</string>", position);
            return end == std::string::npos ? std::string() : plist.substr(position, end - position);
        };
        const std::string version = valueAfter("CFBundleShortVersionString");
        const std::string build = valueAfter("ProductBuildVersion");
        if (!version.empty() && !build.empty())
        {
            return version + " (" + build + ")";
        }
    }
    catch (const std::exception&)
    {
    }
    return "unavailable";
}

#if LL_DARWIN
bool nativeWindowIsPresentable(LLWindow* window)
{
    id native_window = static_cast<id>(window ? window->getPlatformWindow() : nullptr);
    if (!native_window)
    {
        return false;
    }

    const Class window_class = object_getClass(native_window);
    const SEL visible_selector = sel_registerName("isVisible");
    const SEL miniaturized_selector = sel_registerName("isMiniaturized");
    const SEL occlusion_selector = sel_registerName("occlusionState");
    if (!window_class || !class_respondsToSelector(window_class, visible_selector) ||
        !class_respondsToSelector(window_class, miniaturized_selector) ||
        !class_respondsToSelector(window_class, occlusion_selector))
    {
        return false;
    }

    using BoolMessage = BOOL (*)(id, SEL);
    using IntegerMessage = unsigned long (*)(id, SEL);
    const auto bool_message = reinterpret_cast<BoolMessage>(objc_msgSend);
    const auto integer_message = reinterpret_cast<IntegerMessage>(objc_msgSend);
    constexpr unsigned long WINDOW_OCCLUSION_STATE_VISIBLE = 1UL << 1;
    return bool_message(native_window, visible_selector) &&
           !bool_message(native_window, miniaturized_selector) &&
           (integer_message(native_window, occlusion_selector) & WINDOW_OCCLUSION_STATE_VISIBLE) != 0;
}

CGDirectDisplayID nativeWindowDisplay(LLWindow* window)
{
    id native_window = static_cast<id>(window ? window->getPlatformWindow() : nullptr);
    if (!native_window)
    {
        return kCGNullDirectDisplay;
    }

    const Class window_class = object_getClass(native_window);
    const SEL number_selector = sel_registerName("windowNumber");
    if (!window_class || !class_respondsToSelector(window_class, number_selector))
    {
        return kCGNullDirectDisplay;
    }
    using WindowNumberMessage = long (*)(id, SEL);
    const long window_number = reinterpret_cast<WindowNumberMessage>(objc_msgSend)(native_window, number_selector);
    if (window_number <= 0 || static_cast<unsigned long>(window_number) > std::numeric_limits<CGWindowID>::max())
    {
        return kCGNullDirectDisplay;
    }

    CFArrayRef descriptions = CGWindowListCopyWindowInfo(
        kCGWindowListOptionIncludingWindow, static_cast<CGWindowID>(window_number));
    if (!descriptions || CFArrayGetCount(descriptions) != 1)
    {
        if (descriptions)
        {
            CFRelease(descriptions);
        }
        return kCGNullDirectDisplay;
    }

    CGRect window_bounds = CGRectNull;
    const auto description = static_cast<CFDictionaryRef>(
        CFArrayGetValueAtIndex(descriptions, 0));
    const auto bounds = static_cast<CFDictionaryRef>(
        CFDictionaryGetValue(description, kCGWindowBounds));
    const bool have_bounds = bounds && CGRectMakeWithDictionaryRepresentation(bounds, &window_bounds);
    CFRelease(descriptions);
    if (!have_bounds || CGRectIsNull(window_bounds) || CGRectIsEmpty(window_bounds))
    {
        return kCGNullDirectDisplay;
    }

    std::array<CGDirectDisplayID, 32> displays{};
    uint32_t display_count = 0;
    if (CGGetActiveDisplayList(displays.size(), displays.data(), &display_count) != kCGErrorSuccess ||
        display_count == 0)
    {
        return kCGNullDirectDisplay;
    }

    CGDirectDisplayID selected = kCGNullDirectDisplay;
    double selected_area = 0.0;
    for (uint32_t index = 0; index < display_count; ++index)
    {
        const CGRect intersection = CGRectIntersection(window_bounds, CGDisplayBounds(displays[index]));
        const double area = CGRectIsNull(intersection) || CGRectIsEmpty(intersection)
            ? 0.0
            : static_cast<double>(CGRectGetWidth(intersection)) * CGRectGetHeight(intersection);
        if (area > selected_area)
        {
            selected = displays[index];
            selected_area = area;
        }
    }
    return selected;
}
#endif

struct Artifact
{
    std::string path;
    U64 bytes = 0;
    std::string sha256;
};

struct CaptureArtifact : Artifact
{
    U32 ordinal = 0;
    U64 frame_serial = 0;
    U64 capture_state_generation = 0;
    std::string transaction_id;
};

struct SupportingArtifact : Artifact
{
    std::string role;
    U64 frame_serial = 0;
    U64 capture_state_generation = 0;
    std::string transaction_id;
};

struct PendingSample
{
    U64 frame_serial = 0;
    U64 capture_state_generation = 0;
    double cpu_ms = 0.0;
    U64 process_resident_bytes = 0;
    U64 renderer_accounted_gpu_bytes = 0;
    GLuint query = 0;
};

struct PendingPresentation
{
    lloracle::FramePhase phase = lloracle::FramePhase::COMPLETE;
    U64 frame_serial = 0;
    U64 capture_state_generation = 0;
    double cpu_ms = 0.0;
    U64 process_resident_bytes = 0;
    U64 renderer_accounted_gpu_bytes = 0;
    GLuint query = 0;
    U32 capture_ordinal = 0;
    std::vector<U8> captured_color;
    std::vector<U8> captured_depth;
    std::string capture_transaction_id;
    bool valid = false;
};

struct PackState
{
    GLint alignment = 0;
    GLint row_length = 0;
    GLint image_height = 0;
    GLint skip_rows = 0;
    GLint skip_pixels = 0;
    GLint skip_images = 0;
    GLint swap_bytes = 0;
    GLint lsb_first = 0;
    GLint pixel_pack_buffer = 0;

    PackState()
    {
        glGetIntegerv(GL_PACK_ALIGNMENT, &alignment);
        glGetIntegerv(GL_PACK_ROW_LENGTH, &row_length);
        glGetIntegerv(GL_PACK_IMAGE_HEIGHT, &image_height);
        glGetIntegerv(GL_PACK_SKIP_ROWS, &skip_rows);
        glGetIntegerv(GL_PACK_SKIP_PIXELS, &skip_pixels);
        glGetIntegerv(GL_PACK_SKIP_IMAGES, &skip_images);
        glGetIntegerv(GL_PACK_SWAP_BYTES, &swap_bytes);
        glGetIntegerv(GL_PACK_LSB_FIRST, &lsb_first);
        glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pixel_pack_buffer);
    }

    ~PackState()
    {
        glBindBuffer(GL_PIXEL_PACK_BUFFER, static_cast<GLuint>(pixel_pack_buffer));
        glPixelStorei(GL_PACK_ALIGNMENT, alignment);
        glPixelStorei(GL_PACK_ROW_LENGTH, row_length);
        glPixelStorei(GL_PACK_IMAGE_HEIGHT, image_height);
        glPixelStorei(GL_PACK_SKIP_ROWS, skip_rows);
        glPixelStorei(GL_PACK_SKIP_PIXELS, skip_pixels);
        glPixelStorei(GL_PACK_SKIP_IMAGES, skip_images);
        glPixelStorei(GL_PACK_SWAP_BYTES, swap_bytes);
        glPixelStorei(GL_PACK_LSB_FIRST, lsb_first);
    }
};

class Controller
{
public:
    Controller(const fs::path& request_path, const fs::path& output_directory)
    :   mSequence(ORACLE_WARMUP_FRAMES, ORACLE_MEASUREMENT_FRAMES, ORACLE_CAPTURE_FRAMES),
        mRequestPath(request_path),
        mOutputDirectory(output_directory),
        mProcessRunId(LLUUID::generateNewID().asString())
    {
        loadRequest();
    }

    ~Controller()
    {
        shutdown();
    }

    void shutdown()
    {
        cleanupUnpublishedResources();
    }

    bool arm(const std::string& request_sha256, std::string& error)
    {
        if (mStage != Stage::CONFIGURED)
        {
            error = "oracle capture is not in the configured state";
            return false;
        }
        if (!isLowerHex(request_sha256, 64) || request_sha256 != mRequestSha256)
        {
            error = "arm request SHA-256 does not match the configured request";
            fail(error);
            return false;
        }

        try
        {
            boost::json::object observed;
            if (!observeState(observed) || canonicalJson(observed) != canonicalJson(mExpectedState))
            {
                error = "runtime state does not match the self-test capture contract";
                fail(error);
                return false;
            }
#if LL_DARWIN
            CGLContextObj context = CGLGetCurrentContext();
            if (!context)
            {
                error = "no current OpenGL context";
                fail(error);
                return false;
            }
#endif
            prepareOutputDirectory();
            mObservedState = std::move(observed);
            ++mCaptureStateGeneration;
#if LL_DARWIN
            mContext = context;
#endif
            transition(Stage::ARMED);
            return true;
        }
        catch (const std::exception& exception)
        {
            error = exception.what();
            fail(error);
            return false;
        }
    }

    bool active() const
    {
        return mStage == Stage::ARMED || mStage == Stage::WARMUP ||
               mStage == Stage::MEASUREMENT || mStage == Stage::CAPTURE;
    }

    bool displayActive() const
    {
        return mDisplayActive;
    }

    LLSD status() const
    {
        LLSD result;
        result["schema"] = 1;
        result["slot_id"] = mSlotId;
        result["request_sha256"] = mRequestSha256;
        result["state"] = stageName(mStage);
        result["generation"] = static_cast<LLSD::Integer>(mCaptureStateGeneration);
        result["warmup_presented"] = static_cast<LLSD::Integer>(mWarmupFrames.size());
        result["measurement_presented"] = static_cast<LLSD::Integer>(mSamples.size());
        result["capture_presented"] = static_cast<LLSD::Integer>(mCaptures.size());
        result["total_presented"] = static_cast<LLSD::Integer>(mSequence.presentedCount());
        result["error"] = mFailure;
        return result;
    }

    void publishState() const
    {
        LLEventPumps::instance().obtain("OracleCaptureState").post(status());
    }

    bool beginDisplay()
    {
        if (!active() || mSequence.complete())
        {
            return false;
        }
        if (mDisplayActive || mPendingPresentation.valid)
        {
            fail("nested oracle display transaction");
            return false;
        }
        if (gShaderProfileFrame || LLGLSLShader::sProfileEnabled || LLPerfStats::tunables.userAutoTuneEnabled)
        {
            fail("GL_TIME_ELAPSED profiling is active; oracle queries cannot be nested");
            return false;
        }

        boost::json::object observed;
        if (!observeState(observed) || canonicalJson(observed) != canonicalJson(mExpectedState))
        {
            ++mCaptureStateGeneration;
            fail("runtime settings or display state no longer match the capture contract");
            return false;
        }
#if LL_DARWIN
        CGLContextObj context = CGLGetCurrentContext();
        if (!context)
        {
            fail("no current OpenGL context");
            return false;
        }
        if (!mContext)
        {
            mContext = context;
        }
        else if (mContext != context)
        {
            ++mCaptureStateGeneration;
            fail("current OpenGL context changed during acquisition");
            return false;
        }
#endif

        GLint current_query = 0;
        glGetQueryiv(GL_TIME_ELAPSED, GL_CURRENT_QUERY, &current_query);
        if (current_query != 0)
        {
            fail("another GL_TIME_ELAPSED query is active");
            return false;
        }

        if (mStage == Stage::ARMED)
        {
            transition(Stage::WARMUP);
        }

        glGenQueries(1, &mActiveQuery);
        if (mActiveQuery == 0)
        {
            fail("cannot allocate GL_TIME_ELAPSED query");
            return false;
        }
        mCpuStart = Clock::now();
        glBeginQuery(GL_TIME_ELAPSED, mActiveQuery);
        mDisplayActive = true;
        return true;
    }

    bool beforePresent()
    {
        if (!mDisplayActive || mFailed)
        {
            return false;
        }

        GLint current_query = 0;
        glGetQueryiv(GL_TIME_ELAPSED, GL_CURRENT_QUERY, &current_query);
        if (current_query != static_cast<GLint>(mActiveQuery))
        {
            fail("oracle GL_TIME_ELAPSED query was interrupted by nested profiling");
            return false;
        }
        glEndQuery(GL_TIME_ELAPSED);
        const auto cpu_end = Clock::now();

        if (!validatePresentationState())
        {
            fail("pre-swap OpenGL or display state does not satisfy the request");
            return false;
        }

        boost::json::object observed;
        if (!observeState(observed) || canonicalJson(observed) != canonicalJson(mObservedState))
        {
            ++mCaptureStateGeneration;
            fail("validated capture state changed during a display transaction");
            return false;
        }

        mPendingPresentation.phase = mSequence.phase();
        mPendingPresentation.frame_serial = mSequence.frameSerial();
        mPendingPresentation.capture_state_generation = mCaptureStateGeneration;
        mPendingPresentation.cpu_ms =
            std::chrono::duration<double, std::milli>(cpu_end - mCpuStart).count();
        mPendingPresentation.process_resident_bytes = LLMemory::getCurrentRSS();
        if (mPendingPresentation.process_resident_bytes == 0)
        {
            fail("process resident memory telemetry is unavailable");
            return false;
        }
        mPendingPresentation.renderer_accounted_gpu_bytes =
            LLImageGL::getTextureBytesAllocated() + LLVertexBuffer::getBytesAllocated() +
            static_cast<U64>(LLRenderTarget::sBytesAllocated);
        mPendingPresentation.query = mActiveQuery;

        if (mPendingPresentation.phase == lloracle::FramePhase::CAPTURE)
        {
            const U32 ordinal = static_cast<U32>(
                mPendingPresentation.frame_serial - ORACLE_WARMUP_FRAMES - ORACLE_MEASUREMENT_FRAMES);
            if (!readCapture(ordinal, mPendingPresentation))
            {
                fail("cannot capture the pre-swap framebuffer");
                return false;
            }
        }

        mActiveQuery = 0;
        mDisplayActive = false;
        mPendingPresentation.valid = true;
        return true;
    }

    void didPresent()
    {
        if (mFailed || !mPendingPresentation.valid)
        {
            return;
        }
        if (mPendingPresentation.frame_serial != mSequence.frameSerial() ||
            mPendingPresentation.phase != mSequence.phase())
        {
            fail("oracle presentation state machine diverged");
            return;
        }

        switch (mPendingPresentation.phase)
        {
        case lloracle::FramePhase::WARMUP:
            mWarmupFrames.push_back(mPendingPresentation.frame_serial);
            glDeleteQueries(1, &mPendingPresentation.query);
            break;
        case lloracle::FramePhase::MEASUREMENT:
            mSamples.push_back(PendingSample{
                mPendingPresentation.frame_serial,
                mPendingPresentation.capture_state_generation,
                mPendingPresentation.cpu_ms,
                mPendingPresentation.process_resident_bytes,
                mPendingPresentation.renderer_accounted_gpu_bytes,
                mPendingPresentation.query});
            break;
        case lloracle::FramePhase::CAPTURE:
            try
            {
                commitCapture(mPendingPresentation);
            }
            catch (const std::exception& error)
            {
                glDeleteQueries(1, &mPendingPresentation.query);
                fail(error.what());
                return;
            }
            glDeleteQueries(1, &mPendingPresentation.query);
            break;
        case lloracle::FramePhase::COMPLETE:
            fail("unexpected presentation after oracle acquisition completed");
            return;
        }

        mPendingPresentation = PendingPresentation{};
        mSequence.presented();
        if (mSequence.complete())
        {
            try
            {
                finalize();
                transition(Stage::COMPLETE);
                LL_INFOS("OracleCapture") << "Oracle acquisition receipt is durable at "
                                           << (mOutputDirectory / "receipt.json").string() << LL_ENDL;
                LLAppViewer::instance()->forceQuit();
            }
            catch (const std::exception& error)
            {
                fail(error.what());
            }
        }
        else if (mSequence.phase() == lloracle::FramePhase::MEASUREMENT)
        {
            transition(Stage::MEASUREMENT);
        }
        else if (mSequence.phase() == lloracle::FramePhase::CAPTURE)
        {
            transition(Stage::CAPTURE);
        }
    }

    void presentationFailed()
    {
        fail("platform buffer presentation failed");
    }

    void cancelDisplay()
    {
        const GLuint active_query = mActiveQuery;
        const GLuint pending_query = mPendingPresentation.query;
        if (canManageQueries())
        {
            GLint current_query = 0;
            if (mDisplayActive && active_query != 0)
            {
                glGetQueryiv(GL_TIME_ELAPSED, GL_CURRENT_QUERY, &current_query);
                if (current_query == static_cast<GLint>(active_query))
                {
                    glEndQuery(GL_TIME_ELAPSED);
                }
            }
            if (active_query != 0)
            {
                glDeleteQueries(1, &active_query);
            }
            if (pending_query != 0 && pending_query != active_query)
            {
                glDeleteQueries(1, &pending_query);
            }
        }
        mActiveQuery = 0;
        mDisplayActive = false;
        mPendingPresentation = PendingPresentation{};
    }

private:
    bool canManageQueries() const
    {
#if LL_DARWIN
        return mContext && CGLGetCurrentContext() == mContext;
#else
        return true;
#endif
    }

    enum class Stage
    {
        CONFIGURED,
        ARMED,
        WARMUP,
        MEASUREMENT,
        CAPTURE,
        COMPLETE,
        FAILED
    };

    static const char* stageName(Stage stage)
    {
        switch (stage)
        {
        case Stage::CONFIGURED: return "configured";
        case Stage::ARMED: return "armed";
        case Stage::WARMUP: return "warmup";
        case Stage::MEASUREMENT: return "measurement";
        case Stage::CAPTURE: return "capture";
        case Stage::COMPLETE: return "complete";
        case Stage::FAILED: return "failed";
        }
        return "failed";
    }

    void transition(Stage stage)
    {
        if (mStage != stage)
        {
            mStage = stage;
            publishState();
        }
    }

    void loadRequest()
    {
        if (!mRequestPath.is_absolute() || fs::canonical(mRequestPath) != mRequestPath.lexically_normal() ||
            !fs::is_regular_file(mRequestPath) || fs::is_symlink(mRequestPath))
        {
            throw CaptureError("oracle request must be a canonical absolute regular file");
        }
        mRequestBytes = readFile(mRequestPath, MAX_REQUEST_BYTES);
        mRequestSha256 = sha256(mRequestBytes);

        boost::system::error_code parse_error;
        mRequest = boost::json::parse(
            std::string_view(reinterpret_cast<const char*>(mRequestBytes.data()), mRequestBytes.size()),
            parse_error);
        if (parse_error || !mRequest.is_object())
        {
            throw CaptureError("oracle request is not a JSON object");
        }
        const auto& request = mRequest.as_object();
        requireExactKeys(
            request,
            {"schema", "kind", "session_id", "slot_id", "corpus_sha256", "baseline", "definition",
             "definition_sha256", "conditions", "conditions_sha256", "capture_contract", "warmup_frames",
             "measurement_frames", "capture_repetitions", "required_supporting_artifacts", "definition_status",
             "definition_blockers", "machine_contract_status", "machine_contract_blockers", "machine_contract"},
            "request");
        if (requireInteger(request, "schema") != 2 ||
            requireString(request, "kind") != "firestorm-opengl-oracle-request")
        {
            throw CaptureError("unsupported oracle request schema or kind");
        }

        mSessionId = requireString(request, "session_id");
        mSlotId = requireString(request, "slot_id");
        mCorpusSha256 = requireString(request, "corpus_sha256");
        mDefinitionSha256 = requireString(request, "definition_sha256");
        mConditionsSha256 = requireString(request, "conditions_sha256");
        if (!isUuid(mSessionId) || !isLowerHex(mCorpusSha256, 64) ||
            !isLowerHex(mDefinitionSha256, 64) || !isLowerHex(mConditionsSha256, 64))
        {
            throw CaptureError("request identity hashes or session UUID are invalid");
        }

        const auto& baseline = requireObject(requireField(request, "baseline"), "baseline");
        requireExactKeys(baseline, {"remote", "commit", "renderer"}, "baseline");
        mBaselineCommit = requireString(baseline, "commit");
        if (!isLowerHex(mBaselineCommit, 40) || requireString(baseline, "renderer") != "OpenGL")
        {
            throw CaptureError("request baseline is not a pinned OpenGL commit");
        }
        requireString(baseline, "remote");

        const auto& definition = requireField(request, "definition");
        const auto& conditions = requireObject(requireField(request, "conditions"), "conditions");
        if (canonicalHash(definition) != mDefinitionSha256 || canonicalHash(conditions) != mConditionsSha256)
        {
            throw CaptureError("request definition or conditions hash mismatch");
        }

        const auto& definition_blockers = requireArray(requireField(request, "definition_blockers"), "definition_blockers");
        const auto& machine_blockers = requireArray(requireField(request, "machine_contract_blockers"), "machine_contract_blockers");
        if (requireString(request, "definition_status") != "ready" || !definition_blockers.empty() ||
            requireString(request, "machine_contract_status") != "ready" || !machine_blockers.empty())
        {
            throw CaptureError("blocked oracle request cannot be acquired");
        }

        const auto& contract = requireObject(requireField(request, "capture_contract"), "capture_contract");
        requireExactKeys(
            contract,
            {"repetitions", "warmup_frames", "measurement_frames", "capture_format", "capture_encoding",
             "png_interlaced", "self_variance_method", "cpu_timing_scope", "gpu_timing_scope",
             "gpu_memory_method", "renderer_accounted_gpu_memory_sources", "platform", "notes"},
            "capture_contract");
        if (requireInteger(request, "warmup_frames") != ORACLE_WARMUP_FRAMES ||
            requireInteger(request, "measurement_frames") != ORACLE_MEASUREMENT_FRAMES ||
            requireInteger(request, "capture_repetitions") != ORACLE_CAPTURE_FRAMES ||
            requireInteger(contract, "warmup_frames") != ORACLE_WARMUP_FRAMES ||
            requireInteger(contract, "measurement_frames") != ORACLE_MEASUREMENT_FRAMES ||
            requireInteger(contract, "repetitions") != ORACLE_CAPTURE_FRAMES)
        {
            throw CaptureError("oracle acquisition requires exactly 300 warmup, 600 measured, and 3 capture frames");
        }
        if (requireString(contract, "capture_format") != "png" ||
            requireString(contract, "capture_encoding") != "rgb_or_rgba8_srgb" ||
            requireField(contract, "png_interlaced").is_bool() == false ||
            requireField(contract, "png_interlaced").as_bool())
        {
            throw CaptureError("unsupported oracle capture image contract");
        }
        if (requireString(contract, "self_variance_method") != "linear_srgb_rgba8_all_pairs_v1" ||
            requireString(contract, "cpu_timing_scope") != "display_to_pre_swap_wall_v1" ||
            requireString(contract, "gpu_timing_scope") != "gl_time_elapsed_frame_v1" ||
            requireString(contract, "gpu_memory_method") != "renderer_accounted_v1")
        {
            throw CaptureError("unsupported oracle timing, memory, or self-variance contract");
        }
        const auto& memory_sources = requireArray(
            requireField(contract, "renderer_accounted_gpu_memory_sources"),
            "capture_contract.renderer_accounted_gpu_memory_sources");
        const std::array<std::string, 3> expected_memory_sources = {
            "viewer texture allocation counters",
            "viewer vertex-buffer allocation counters",
            "viewer render-target attachment accounting"};
        if (memory_sources.size() != expected_memory_sources.size())
        {
            throw CaptureError("renderer-accounted GPU memory sources do not match the protocol");
        }
        for (std::size_t index = 0; index < expected_memory_sources.size(); ++index)
        {
            if (!memory_sources[index].is_string() ||
                memory_sources[index].as_string() != expected_memory_sources[index])
            {
                throw CaptureError("renderer-accounted GPU memory sources do not match the protocol");
            }
        }
        const auto& notes = requireArray(requireField(contract, "notes"), "capture_contract.notes");
        if (std::any_of(notes.begin(), notes.end(), [](const boost::json::value& note)
            { return !note.is_string() || note.as_string().empty(); }))
        {
            throw CaptureError("capture_contract.notes must contain only non-empty strings");
        }
        const auto& platform = requireObject(requireField(contract, "platform"), "capture_contract.platform");
        requireExactKeys(platform, {"os", "architecture"}, "capture_contract.platform");
        if (requireString(platform, "os") != "macOS" || requireString(platform, "architecture") != "arm64")
        {
            throw CaptureError("oracle acquisition is restricted to macOS arm64");
        }

        mInstrumentationCommit = LL_ORACLE_INSTRUMENTATION_COMMIT;
        if (!isLowerHex(mInstrumentationCommit, 40))
        {
            throw CaptureError("instrumentation build does not embed a full clean Git commit");
        }
        const fs::path executable(gDirUtilp->getExecutablePathAndName());
        mExecutableSha256 = sha256(readFile(executable, std::numeric_limits<std::size_t>::max()));

        const auto& machine_contract = requireObject(requireField(request, "machine_contract"), "machine_contract");
        requireExactKeys(machine_contract, {"schema", "kind", "expected", "producer"}, "machine_contract");
        if (requireInteger(machine_contract, "schema") != 1 ||
            !lloracle::isSupportedMachineContractKind(requireString(machine_contract, "kind")))
        {
            throw CaptureError(
                "this instrumentation supports only inadmissible capture_self_test_v1 machine contracts");
        }
        const auto& expected = requireObject(requireField(machine_contract, "expected"), "machine_contract.expected");
        requireExactKeys(expected, {"runtime_settings", "display"}, "machine_contract.expected");
        const auto& runtime_settings = requireObject(requireField(expected, "runtime_settings"), "runtime_settings");
        const auto& display = requireObject(requireField(expected, "display"), "display");
        requireExactKeys(display, {"width_px", "height_px", "scale_factor", "color_space", "window_mode"}, "display");
        const auto& condition_settings = requireObject(requireField(conditions, "settings"), "conditions.settings");
        const auto& condition_display = requireObject(requireField(conditions, "display"), "conditions.display");
        if (canonicalJson(runtime_settings) != canonicalJson(condition_settings) ||
            canonicalJson(display) != canonicalJson(condition_display))
        {
            throw CaptureError("machine contract does not exactly bind the request conditions");
        }
        const auto& producer = requireObject(requireField(machine_contract, "producer"), "machine_contract.producer");
        requireExactKeys(producer, {"instrumentation_commit", "executable_sha256"}, "machine_contract.producer");
        if (requireString(producer, "instrumentation_commit") != mInstrumentationCommit ||
            requireString(producer, "executable_sha256") != mExecutableSha256)
        {
            throw CaptureError("machine contract does not bind this clean instrumentation executable");
        }

        const S64 width = requireInteger(display, "width_px");
        const S64 height = requireInteger(display, "height_px");
        if (width <= 0 || height <= 0 || width > std::numeric_limits<U16>::max() ||
            height > std::numeric_limits<U16>::max() ||
            static_cast<U64>(width) * static_cast<U64>(height) > MAX_CAPTURE_BYTES / 4)
        {
            throw CaptureError("requested display dimensions exceed the capture limit");
        }
        if (requireNumber(display, "scale_factor") < 1.0 || requireString(display, "color_space") != "sRGB" ||
            !lloracle::isSupportedSelfTestWindowMode(requireString(display, "window_mode")))
        {
            throw CaptureError("unsupported display contract");
        }
        mWidth = static_cast<U32>(width);
        mHeight = static_cast<U32>(height);
        mExpectedState = expected;

        const auto& supporting = requireObject(
            requireField(request, "required_supporting_artifacts"), "required_supporting_artifacts");
        for (const auto& member : supporting)
        {
            const std::string role(member.key());
            if (role != "local_snapshot" && role != "raw_color" && role != "raw_depth")
            {
                throw CaptureError("capture_self_test_v1 cannot produce supporting role " + role);
            }
            mSupportingContracts.emplace(role, member.value());
        }
        validateSupportingContracts();
    }

    void validateSupportingContracts()
    {
        for (const auto& [role, value] : mSupportingContracts)
        {
            const auto& contract = requireObject(value, "supporting contract " + role);
            if (role == "local_snapshot")
            {
                requireExactKeys(contract, {"kind", "encoding", "width_px", "height_px", "interlaced"}, role);
                if (requireString(contract, "kind") != "png" ||
                    requireString(contract, "encoding") != "rgb_or_rgba8_srgb_encoded" ||
                    requireInteger(contract, "width_px") != mWidth || requireInteger(contract, "height_px") != mHeight ||
                    !requireField(contract, "interlaced").is_bool() || requireField(contract, "interlaced").as_bool())
                {
                    throw CaptureError("invalid local_snapshot contract");
                }
            }
            else
            {
                requireExactKeys(
                    contract,
                    {"kind", "encoding", "origin", "width_px", "height_px", "row_pitch_bytes", "bytes"},
                    role);
                const std::string expected_encoding = role == "raw_color"
                    ? "bgra8_unorm_srgb_encoded"
                    : "depth32_float_le_zero_to_one";
                const U64 bytes = static_cast<U64>(mWidth) * mHeight * 4;
                if (requireString(contract, "kind") != "raw" ||
                    requireString(contract, "encoding") != expected_encoding ||
                    requireString(contract, "origin") != "top_left" ||
                    requireInteger(contract, "width_px") != mWidth || requireInteger(contract, "height_px") != mHeight ||
                    requireInteger(contract, "row_pitch_bytes") != static_cast<S64>(mWidth * 4) ||
                    requireInteger(contract, "bytes") != static_cast<S64>(bytes))
                {
                    throw CaptureError("invalid " + role + " contract");
                }
            }
        }
    }

    void prepareOutputDirectory()
    {
        if (!mOutputDirectory.is_absolute())
        {
            throw CaptureError("oracle output directory must be an absolute path");
        }
        const fs::path requested = mOutputDirectory.lexically_normal();
        if (fs::exists(requested))
        {
            throw CaptureError("oracle output path must not already exist");
        }
        if (fs::is_symlink(requested))
        {
            throw CaptureError("oracle output path must not be a symlink");
        }
        const fs::path parent = requested.parent_path();
        if (parent.empty() || fs::is_symlink(parent) || !fs::is_directory(parent) || fs::canonical(parent) != parent)
        {
            throw CaptureError("oracle output parent must be a canonical real directory");
        }
        mOutputDirectory = requested;
        mStagingDirectory = parent / ("." + requested.filename().string() + ".staging-" + mProcessRunId);
        if (fs::exists(mStagingDirectory) || fs::is_symlink(mStagingDirectory))
        {
            throw CaptureError("oracle staging path is occupied");
        }
        if (!fs::create_directory(mStagingDirectory))
        {
            throw CaptureError("cannot create oracle staging directory");
        }
        mOutputPublicationState = lloracle::OutputPublicationState::STAGING_OWNED;
        if (::chmod(mStagingDirectory.c_str(), 0700) != 0)
        {
            throw CaptureError("cannot make oracle staging directory private");
        }
    }

    bool observeState(boost::json::object& observed) const
    {
        const auto& expected_settings = requireObject(
            requireField(mExpectedState, "runtime_settings"), "expected.runtime_settings");
        boost::json::object runtime_settings;
        for (const auto& member : expected_settings)
        {
            LLControlVariablePtr control = gSavedSettings.getControl(member.key());
            if (!control)
            {
                return false;
            }
            runtime_settings.emplace(member.key(), LlsdToJson(control->getValue()));
        }

        if (!gViewerWindow || !gViewerWindow->getWindow() || !gViewerWindow->getActive() ||
            !gViewerWindow->getWindow()->getVisible() || gViewerWindow->getWindow()->getMinimized() ||
            gViewerWindow->getWindow()->getFullscreen()
#if LL_DARWIN
            || !nativeWindowIsPresentable(gViewerWindow->getWindow())
#endif
        )
        {
            return false;
        }
        LLCoordWindow size;
        if (!gViewerWindow->getWindow()->getSize(&size))
        {
            return false;
        }

        boost::json::object display;
        display.emplace("width_px", size.mX);
        display.emplace("height_px", size.mY);
        display.emplace("scale_factor", static_cast<double>(gViewerWindow->getWindow()->getSystemUISize()));
        display.emplace("color_space", "sRGB");
        display.emplace("window_mode", "windowed_visible_not_minimized");

        observed.emplace("runtime_settings", std::move(runtime_settings));
        observed.emplace("display", std::move(display));
        return true;
    }

    bool validatePresentationState() const
    {
#if !LL_DARWIN
        return false;
#else
        CGLContextObj context = CGLGetCurrentContext();
        if (!context || context != mContext)
        {
            return false;
        }
        GLint backing[2] = {0, 0};
        if (CGLGetParameter(context, kCGLCPSurfaceBackingSize, backing) != kCGLNoError ||
            backing[0] != static_cast<GLint>(mWidth) || backing[1] != static_cast<GLint>(mHeight))
        {
            return false;
        }
        GLint draw_framebuffer = -1;
        GLint read_framebuffer = -1;
        GLint read_buffer = 0;
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw_framebuffer);
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_framebuffer);
        glGetIntegerv(GL_READ_BUFFER, &read_buffer);
        return draw_framebuffer == 0 && read_framebuffer == 0 && read_buffer == GL_BACK &&
               glIsEnabled(GL_FRAMEBUFFER_SRGB) == GL_FALSE;
#endif
    }

    std::vector<U8> encodePng(const std::vector<U8>& top_left_bgra) const
    {
        LLPointer<LLImageRaw> raw = new LLImageRaw(static_cast<U16>(mWidth), static_cast<U16>(mHeight), 4);
        if (raw.isNull() || !raw->getData())
        {
            throw CaptureError("cannot allocate PNG source image");
        }

        U8* destination = raw->getData();
        const std::size_t source_pitch = static_cast<std::size_t>(mWidth) * 4;
        for (U32 top = 0; top < mHeight; ++top)
        {
            const U8* source = top_left_bgra.data() + static_cast<std::size_t>(top) * source_pitch;
            U8* target = destination + static_cast<std::size_t>(mHeight - 1 - top) * source_pitch;
            for (U32 x = 0; x < mWidth; ++x)
            {
                target[x * 4] = source[x * 4 + 2];
                target[x * 4 + 1] = source[x * 4 + 1];
                target[x * 4 + 2] = source[x * 4];
                target[x * 4 + 3] = source[x * 4 + 3];
            }
        }

        LLPointer<LLImagePNG> png = new LLImagePNG();
        if (png.isNull() || !png->encode(raw, 0.0f) || !png->getData() || png->getDataSize() <= 0)
        {
            throw CaptureError("cannot encode noninterlaced RGBA PNG");
        }
        return std::vector<U8>(png->getData(), png->getData() + png->getDataSize());
    }

    Artifact stageArtifact(const std::string& relative_path, const std::vector<U8>& bytes)
    {
        if (!lloracle::isSafeRelativePath(relative_path) || bytes.empty())
        {
            throw CaptureError("unsafe or empty oracle artifact");
        }
        const fs::path destination = mStagingDirectory / fs::path(relative_path);
        const fs::path parent = destination.parent_path();
        fs::create_directories(parent);
        if (fs::is_symlink(parent) || fs::exists(destination))
        {
            throw CaptureError("oracle artifact staging path is aliased or occupied");
        }
        writeDurable(destination, bytes);
        mStagedPaths.push_back(relative_path);
        return Artifact{relative_path, static_cast<U64>(bytes.size()), sha256(bytes)};
    }

    bool readCapture(U32 ordinal, PendingPresentation& presentation)
    {
        try
        {
            if (glGetError() != GL_NO_ERROR)
            {
                throw CaptureError("pre-existing OpenGL error before oracle readback");
            }
            const std::size_t byte_count = static_cast<std::size_t>(mWidth) * mHeight * 4;
            {
                PackState saved_pack_state;
                glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
                glPixelStorei(GL_PACK_ALIGNMENT, 1);
                glPixelStorei(GL_PACK_ROW_LENGTH, 0);
                glPixelStorei(GL_PACK_IMAGE_HEIGHT, 0);
                glPixelStorei(GL_PACK_SKIP_ROWS, 0);
                glPixelStorei(GL_PACK_SKIP_PIXELS, 0);
                glPixelStorei(GL_PACK_SKIP_IMAGES, 0);
                glPixelStorei(GL_PACK_SWAP_BYTES, GL_FALSE);
                glPixelStorei(GL_PACK_LSB_FIRST, GL_FALSE);

                presentation.captured_color.resize(byte_count);
                presentation.captured_depth.resize(byte_count);
                glReadPixels(
                    0, 0, mWidth, mHeight, GL_BGRA, GL_UNSIGNED_BYTE, presentation.captured_color.data());
                if (glGetError() != GL_NO_ERROR)
                {
                    throw CaptureError("BGRA8 framebuffer readback failed");
                }
                glReadPixels(
                    0, 0, mWidth, mHeight, GL_DEPTH_COMPONENT, GL_FLOAT, presentation.captured_depth.data());
                if (glGetError() != GL_NO_ERROR)
                {
                    throw CaptureError("depth32 framebuffer readback failed");
                }
            }
            presentation.capture_ordinal = ordinal;
            presentation.capture_transaction_id = LLUUID::generateNewID().asString();
            return true;
        }
        catch (const std::exception& error)
        {
            LL_WARNS("OracleCapture") << error.what() << LL_ENDL;
            return false;
        }
    }

    void commitCapture(PendingPresentation& presentation)
    {
        if (presentation.capture_ordinal == 0 || presentation.captured_color.empty() ||
            presentation.captured_depth.empty() || presentation.capture_transaction_id.empty())
        {
            throw CaptureError("presented oracle capture transaction is incomplete");
        }

        const std::size_t row_bytes = static_cast<std::size_t>(mWidth) * 4;
        lloracle::flipRows(presentation.captured_color, row_bytes, mHeight);
        lloracle::flipRows(presentation.captured_depth, row_bytes, mHeight);
        for (std::size_t offset = 0; offset < presentation.captured_depth.size(); offset += sizeof(float))
        {
            float depth = 0.0f;
            std::memcpy(&depth, presentation.captured_depth.data() + offset, sizeof(depth));
            if (!std::isfinite(depth) || depth < 0.0f || depth > 1.0f)
            {
                throw CaptureError("depth readback contains a value outside [0,1]");
            }
        }

        const std::vector<U8> png = encodePng(presentation.captured_color);
        std::ostringstream filename;
        filename << "captures/frame-" << std::setw(2) << std::setfill('0')
                 << presentation.capture_ordinal << ".png";
        const Artifact artifact = stageArtifact(filename.str(), png);
        CaptureArtifact capture;
        capture.path = artifact.path;
        capture.bytes = artifact.bytes;
        capture.sha256 = artifact.sha256;
        capture.ordinal = presentation.capture_ordinal;
        capture.frame_serial = presentation.frame_serial;
        capture.capture_state_generation = presentation.capture_state_generation;
        capture.transaction_id = presentation.capture_transaction_id;
        mCaptures.push_back(std::move(capture));

        if (presentation.capture_ordinal != 1)
        {
            return;
        }

        for (const auto& [role, ignored] : mSupportingContracts)
        {
            (void)ignored;
            const std::vector<U8>* source = nullptr;
            std::string path;
            if (role == "local_snapshot")
            {
                source = &png;
                path = "supporting/local_snapshot.png";
            }
            else if (role == "raw_color")
            {
                source = &presentation.captured_color;
                path = "supporting/raw_color.bgra";
            }
            else if (role == "raw_depth")
            {
                source = &presentation.captured_depth;
                path = "supporting/raw_depth.f32";
            }
            const Artifact artifact = stageArtifact(path, *source);
            SupportingArtifact supporting;
            supporting.path = artifact.path;
            supporting.bytes = artifact.bytes;
            supporting.sha256 = artifact.sha256;
            supporting.role = role;
            supporting.frame_serial = presentation.frame_serial;
            supporting.capture_state_generation = presentation.capture_state_generation;
            supporting.transaction_id = presentation.capture_transaction_id;
            mSupportingArtifacts.push_back(std::move(supporting));
        }
    }

    boost::json::object hardwareMetadata() const
    {
        auto required = [](std::string value, const char* field)
        {
            if (value.empty() || value == "unavailable")
            {
                throw CaptureError(std::string("required hardware metadata is unavailable: ") + field);
            }
            return value;
        };

        const std::string machine_model = required(sysctlString("hw.model"), "machine_model");
        const std::string cpu = required(gSysCPU.getCPUString(), "cpu");
        const std::string gpu = required(
            ll_safe_string(reinterpret_cast<const char*>(glGetString(GL_RENDERER))), "gpu");
        const S64 ram_mib = static_cast<S64>(
            gSysMemory.getPhysicalMemoryKB().valueInUnits<LLUnits::Megabytes>());
        if (ram_mib <= 0)
        {
            throw CaptureError("required hardware metadata is unavailable: ram_mib");
        }
        const std::string os_version = required(LLOSInfo::instance().getOSVersionString(), "os_version");
        const std::string vendor = required(
            ll_safe_string(reinterpret_cast<const char*>(glGetString(GL_VENDOR))), "opengl_vendor");
        const std::string renderer = required(
            ll_safe_string(reinterpret_cast<const char*>(glGetString(GL_RENDERER))), "opengl_renderer");
        const std::string version = required(
            ll_safe_string(reinterpret_cast<const char*>(glGetString(GL_VERSION))), "opengl_version");
        const std::string xcode = required(xcodeBuild(), "xcode_build");
#if LL_DARWIN
        const CGDirectDisplayID display_id = nativeWindowDisplay(
            gViewerWindow ? gViewerWindow->getWindow() : nullptr);
        if (display_id == kCGNullDirectDisplay)
        {
            throw CaptureError("required hardware metadata is unavailable: display_id");
        }
#endif

        boost::json::object hardware;
        hardware.emplace("machine_model", machine_model);
        hardware.emplace("cpu", cpu);
        hardware.emplace("gpu", gpu);
        hardware.emplace("ram_mib", ram_mib);
        hardware.emplace("os_name", "macOS");
        hardware.emplace("os_version", os_version);
        hardware.emplace("architecture", "arm64");
#if LL_DARWIN
        hardware.emplace("display_id", std::to_string(display_id));
#else
        hardware.emplace("display_id", "unavailable");
#endif
        hardware.emplace("display_scale", requireNumber(
            requireObject(requireField(mObservedState, "display"), "observed display"), "scale_factor"));
        hardware.emplace("opengl_vendor", vendor);
        hardware.emplace("opengl_renderer", renderer);
        hardware.emplace("opengl_version", version);
        hardware.emplace("viewer_build", mInstrumentationCommit);
        hardware.emplace("xcode_build", xcode);
        return hardware;
    }

    boost::json::object receipt()
    {
        boost::json::object binding;
        binding.emplace("session_id", mSessionId);
        binding.emplace("slot_id", mSlotId);
        binding.emplace("corpus_sha256", mCorpusSha256);
        binding.emplace("request_sha256", mRequestSha256);
        binding.emplace("definition_sha256", mDefinitionSha256);
        binding.emplace("conditions_sha256", mConditionsSha256);
        binding.emplace("baseline_commit", mBaselineCommit);

        boost::json::object producer;
        producer.emplace("protocol", "firestorm-opengl-oracle-capture-v1");
        producer.emplace("instrumentation_commit", mInstrumentationCommit);
        producer.emplace("executable_sha256", mExecutableSha256);
        producer.emplace("process_run_id", mProcessRunId);

        boost::json::object scopes;
        scopes.emplace("cpu_timing", "display_to_pre_swap_wall_v1");
        scopes.emplace("gpu_timing", "gl_time_elapsed_frame_v1");
        scopes.emplace("gpu_memory", "renderer_accounted_v1");

        boost::json::array warmup;
        for (U64 serial : mWarmupFrames)
        {
            warmup.emplace_back(serial);
        }

        boost::json::array samples;
        for (auto& sample : mSamples)
        {
            if (glGetError() != GL_NO_ERROR)
            {
                throw CaptureError("pre-existing OpenGL error before GPU timing retrieval");
            }
            GLuint64 elapsed_ns = 0;
            glGetQueryObjectui64v(sample.query, GL_QUERY_RESULT, &elapsed_ns);
            const GLenum query_error = glGetError();
            glDeleteQueries(1, &sample.query);
            sample.query = 0;
            if (query_error != GL_NO_ERROR || elapsed_ns == 0)
            {
                throw CaptureError("GPU timing query result is unavailable");
            }

            boost::json::object encoded;
            encoded.emplace("frame_serial", sample.frame_serial);
            encoded.emplace("capture_state_generation", sample.capture_state_generation);
            encoded.emplace("cpu_ms", sample.cpu_ms);
            encoded.emplace("gpu_ms", static_cast<double>(elapsed_ns) / 1'000'000.0);
            encoded.emplace("process_resident_bytes", sample.process_resident_bytes);
            encoded.emplace("renderer_accounted_gpu_bytes", sample.renderer_accounted_gpu_bytes);
            samples.emplace_back(std::move(encoded));
        }

        boost::json::array captures;
        for (const auto& capture : mCaptures)
        {
            boost::json::object encoded;
            encoded.emplace("ordinal", capture.ordinal);
            encoded.emplace("frame_serial", capture.frame_serial);
            encoded.emplace("capture_state_generation", capture.capture_state_generation);
            encoded.emplace("path", capture.path);
            encoded.emplace("bytes", capture.bytes);
            encoded.emplace("sha256", capture.sha256);
            encoded.emplace("transaction_id", capture.transaction_id);
            captures.emplace_back(std::move(encoded));
        }

        boost::json::array supporting;
        for (const auto& artifact : mSupportingArtifacts)
        {
            boost::json::object encoded;
            encoded.emplace("role", artifact.role);
            encoded.emplace("path", artifact.path);
            encoded.emplace("bytes", artifact.bytes);
            encoded.emplace("sha256", artifact.sha256);
            encoded.emplace("frame_serial", artifact.frame_serial);
            encoded.emplace("capture_state_generation", artifact.capture_state_generation);
            encoded.emplace("transaction_id", artifact.transaction_id);
            supporting.emplace_back(std::move(encoded));
        }

        boost::json::object result;
        result.emplace("schema", 1);
        result.emplace("kind", "firestorm-opengl-oracle-acquisition");
        result.emplace("binding", std::move(binding));
        result.emplace("producer", std::move(producer));
        result.emplace("scopes", std::move(scopes));
        result.emplace("hardware_os", hardwareMetadata());
        result.emplace("observed_state", mObservedState);
        result.emplace("capture_state_generation", mCaptureStateGeneration);
        result.emplace("warmup_frames", std::move(warmup));
        result.emplace("samples", std::move(samples));
        result.emplace("captures", std::move(captures));
        result.emplace("supporting_artifacts", std::move(supporting));
        return result;
    }

    void finalize()
    {
        if (mWarmupFrames.size() != ORACLE_WARMUP_FRAMES ||
            mSamples.size() != ORACLE_MEASUREMENT_FRAMES || mCaptures.size() != ORACLE_CAPTURE_FRAMES ||
            mSupportingArtifacts.size() != mSupportingContracts.size())
        {
            throw CaptureError("oracle acquisition counts are incomplete");
        }

        const boost::json::object document = receipt();
        const std::string serialized = boost::json::serialize(document) + "\n";
        const std::vector<U8> receipt_bytes(serialized.begin(), serialized.end());
        const fs::path staged_receipt = mStagingDirectory / "receipt.json";
        writeDurable(staged_receipt, receipt_bytes);

        std::set<fs::path> staging_directories;
        for (const std::string& relative : mStagedPaths)
        {
            staging_directories.insert((mStagingDirectory / relative).parent_path());
        }
        for (const auto& directory : staging_directories)
        {
            syncDirectory(directory);
        }
        syncDirectory(mStagingDirectory);

        const fs::path parent = mOutputDirectory.parent_path();
#if LL_DARWIN
        if (::renameatx_np(
                AT_FDCWD, mStagingDirectory.c_str(), AT_FDCWD, mOutputDirectory.c_str(), RENAME_EXCL) != 0)
        {
            const int rename_error = errno;
            throw CaptureError(
                rename_error == EEXIST
                    ? "oracle output path appeared before publication"
                    : "cannot atomically publish oracle acquisition: " + std::string(std::strerror(rename_error)));
        }
        mOutputPublicationState = lloracle::OutputPublicationState::PUBLISHED;
#else
        throw CaptureError("exclusive oracle acquisition publication is unavailable on this platform");
#endif
        syncDirectory(parent);
    }

    void cleanupUnpublishedResources()
    {
        cancelDisplay();
        if (canManageQueries())
        {
            for (auto& sample : mSamples)
            {
                if (sample.query != 0)
                {
                    glDeleteQueries(1, &sample.query);
                }
            }
        }
        for (auto& sample : mSamples)
        {
            sample.query = 0;
        }

        if (lloracle::hasOwnedUnpublishedStaging(mOutputPublicationState) && !mStagingDirectory.empty())
        {
            std::error_code cleanup_error;
            fs::remove_all(mStagingDirectory, cleanup_error);
            if (cleanup_error)
            {
                LL_WARNS("OracleCapture") << "Cannot remove unpublished acquisition staging directory: "
                                            << cleanup_error.message() << LL_ENDL;
            }
            else
            {
                mOutputPublicationState = lloracle::OutputPublicationState::UNPREPARED;
            }
        }
    }

    void fail(const std::string& message)
    {
        if (mFailed)
        {
            return;
        }
        mFailed = true;
        cleanupUnpublishedResources();
        mFailure = message;
        transition(Stage::FAILED);
        LL_WARNS("OracleCapture") << "Oracle acquisition failed: " << mFailure << LL_ENDL;
        LLApp::setError();
    }

    lloracle::CaptureSequence mSequence;
    fs::path mRequestPath;
    fs::path mOutputDirectory;
    fs::path mStagingDirectory;
    lloracle::OutputPublicationState mOutputPublicationState =
        lloracle::OutputPublicationState::UNPREPARED;
    std::vector<U8> mRequestBytes;
    boost::json::value mRequest;
    boost::json::object mExpectedState;
    boost::json::object mObservedState;
    std::map<std::string, boost::json::value> mSupportingContracts;
    std::vector<std::string> mStagedPaths;
    std::vector<U64> mWarmupFrames;
    std::vector<PendingSample> mSamples;
    std::vector<CaptureArtifact> mCaptures;
    std::vector<SupportingArtifact> mSupportingArtifacts;
    PendingPresentation mPendingPresentation;
    Clock::time_point mCpuStart;
    GLuint mActiveQuery = 0;
#if LL_DARWIN
    CGLContextObj mContext = nullptr;
#endif
    U32 mWidth = 0;
    U32 mHeight = 0;
    U64 mCaptureStateGeneration = 0;
    std::string mSessionId;
    std::string mSlotId;
    std::string mCorpusSha256;
    std::string mRequestSha256;
    std::string mDefinitionSha256;
    std::string mConditionsSha256;
    std::string mBaselineCommit;
    std::string mInstrumentationCommit;
    std::string mExecutableSha256;
    std::string mProcessRunId;
    std::string mFailure;
    Stage mStage = Stage::CONFIGURED;
    bool mDisplayActive = false;
    bool mFailed = false;
};

bool hasExactKeys(const LLSD& value, std::initializer_list<const char*> expected)
{
    if (!value.isMap() || value.size() != expected.size())
    {
        return false;
    }
    for (const char* key : expected)
    {
        if (!value.has(key))
        {
            return false;
        }
    }
    return true;
}

class OracleCaptureEventAPI final : public LLEventAPI
{
public:
    explicit OracleCaptureEventAPI(Controller& controller)
    :   LLEventAPI(
            "LLOracleCapture",
            "Arm and inspect the developer-only OpenGL oracle acquisition controller"),
        mController(controller)
    {
        add("getState", "Return the configured oracle capture state", &OracleCaptureEventAPI::getState);
        add("arm", "Validate and arm the configured oracle request", &OracleCaptureEventAPI::arm);
    }

private:
    void getState(const LLSD& request) const
    {
        Response response(mController.status(), request);
        if (!hasExactKeys(request, {"op", "reply", "reqid"}) ||
            !request["reply"].isString() || request["reply"].asString().empty())
        {
            response.error("getState requires exactly op, reply, and reqid");
        }
    }

    void arm(const LLSD& request)
    {
        std::string error;
        if (!hasExactKeys(request, {"op", "reply", "reqid", "request_sha256"}) ||
            !request["reply"].isString() || request["reply"].asString().empty() ||
            !request["request_sha256"].isString())
        {
            error = "arm requires exactly op, reply, reqid, and request_sha256";
        }
        else
        {
            mController.arm(request["request_sha256"].asString(), error);
        }

        // Standard LLEventAPI replies add the echoed reqid. Unsolicited
        // OracleCaptureState transition events contain only status().
        Response response(mController.status(), request);
        if (!error.empty())
        {
            response.error(error);
        }
    }

    Controller& mController;
};

std::unique_ptr<Controller> gController;
std::unique_ptr<OracleCaptureEventAPI> gEventApi;
}

bool LLOracleCapture::configure(
    const std::string& request_path,
    const std::string& output_directory,
    std::string& error)
{
#if !LL_DARWIN || !LL_ARM64
    (void)request_path;
    (void)output_directory;
    error = "--oracle-capture is supported only on macOS arm64";
    return false;
#else
    if (gController)
    {
        error = "oracle capture was configured more than once";
        return false;
    }
    try
    {
        auto controller = std::make_unique<Controller>(fs::path(request_path), fs::path(output_directory));
        auto event_api = std::make_unique<OracleCaptureEventAPI>(*controller);
        gController = std::move(controller);
        gEventApi = std::move(event_api);
        gController->publishState();
        LL_INFOS("OracleCapture") << "Developer oracle acquisition enabled for request "
                                   << request_path << LL_ENDL;
        return true;
    }
    catch (const std::exception& exception)
    {
        error = exception.what();
        return false;
    }
#endif
}

void LLOracleCapture::shutdown()
{
    if (gController)
    {
        gController->shutdown();
    }
    gEventApi.reset();
    gController.reset();
}

bool LLOracleCapture::enabled()
{
    return gController && gController->active();
}

bool LLOracleCapture::displayActive()
{
    return gController && gController->displayActive();
}

bool LLOracleCapture::beginDisplay()
{
    return enabled() && gController->beginDisplay();
}

bool LLOracleCapture::beforePresent()
{
    return enabled() && gController->beforePresent();
}

void LLOracleCapture::didPresent()
{
    if (gController)
    {
        gController->didPresent();
    }
}

void LLOracleCapture::presentationFailed()
{
    if (gController)
    {
        gController->presentationFailed();
    }
}

void LLOracleCapture::cancelDisplay()
{
    if (gController)
    {
        gController->cancelDisplay();
    }
}

#else // LL_TEST

bool LLOracleCapture::configure(const std::string&, const std::string&, std::string&)
{
    return false;
}

void LLOracleCapture::shutdown() {}
bool LLOracleCapture::enabled() { return false; }
bool LLOracleCapture::displayActive() { return false; }
bool LLOracleCapture::beginDisplay() { return false; }
bool LLOracleCapture::beforePresent() { return false; }
void LLOracleCapture::didPresent() {}
void LLOracleCapture::presentationFailed() {}
void LLOracleCapture::cancelDisplay() {}

#endif // LL_TEST
