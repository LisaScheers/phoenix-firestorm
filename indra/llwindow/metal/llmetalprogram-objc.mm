/**
 * @file llmetalprogram-objc.mm
 * @brief Strong ownership for one explicit declared-program metallib.
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

#include <CommonCrypto/CommonDigest.h>

#include "firestorm-declared-programs.h"
#include "llmetalprogram.h"

#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <set>
#include <sstream>
#include <string>

namespace firestorm::metal
{
namespace
{

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

std::string sha256(const void* bytes, std::size_t size)
{
    if (bytes == nullptr || size == 0 ||
        size > std::numeric_limits<CC_LONG>::max())
    {
        return {};
    }

    unsigned char digest[CC_SHA256_DIGEST_LENGTH]{};
    if (CC_SHA256(bytes, static_cast<CC_LONG>(size), digest) == nullptr)
    {
        return {};
    }

    std::ostringstream result;
    result << std::hex;
    for (unsigned char byte : digest)
    {
        result.width(2);
        result.fill('0');
        result << static_cast<unsigned>(byte);
    }
    return result.str();
}

} // namespace

struct MetalProgramLibrary::Impl
{
    id<MTLDevice>                         device = nil;
    id<MTLLibrary>                        library = nil;
    NSMutableArray<id<MTLFunction>>*      functions = nil;
    std::string                           error;
};

const MetalProgramCatalogMetadata& metalProgramCatalog() noexcept
{
    return declaredMetalProgramCatalog();
}

MetalProgramLibrary::MetalProgramLibrary(MetalDeviceHandle device,
                                         const std::string& metallib_path)
: mImpl(std::make_unique<Impl>())
{
    std::string descriptor_error;
    if (!validateDeclaredMetalPrograms(&descriptor_error))
    {
        mImpl->error = "invalid declared program descriptors: " + descriptor_error;
        return;
    }
    if (device == nullptr)
    {
        mImpl->error = "Metal device is null";
        return;
    }
    if (metallib_path.empty() || metallib_path.find('\0') != std::string::npos)
    {
        mImpl->error = "metallib path must be explicit, nonempty UTF-8 without NUL";
        return;
    }
    NSString* native_path = toNSString(metallib_path);
    if (native_path == nil)
    {
        mImpl->error = "metallib path is not valid UTF-8";
        return;
    }

    NSError* read_error = nil;
    NSData* library_bytes = [NSData dataWithContentsOfFile:native_path
                                                   options:NSDataReadingUncached
                                                     error:&read_error];
    if (library_bytes == nil)
    {
        mImpl->error = "cannot read declared program metallib for verification: " +
                       toString(read_error.localizedDescription);
        return;
    }
    if (library_bytes.length == 0)
    {
        mImpl->error = "declared program metallib is empty";
        return;
    }

    void* exact_bytes = std::malloc(library_bytes.length);
    if (exact_bytes == nullptr)
    {
        mImpl->error = "cannot allocate verified declared program metallib bytes";
        return;
    }
    std::memcpy(exact_bytes, library_bytes.bytes, library_bytes.length);

    const std::string actual_sha256 = sha256(exact_bytes, library_bytes.length);
    const std::string expected_sha256(declaredMetalProgramCatalog().metallibSha256);
    if (actual_sha256.empty() || actual_sha256 != expected_sha256)
    {
        std::free(exact_bytes);
        mImpl->error = "declared program metallib SHA-256 does not match the generated catalog";
        return;
    }

    id<MTLDevice> native_device = (__bridge id<MTLDevice>)device;
    dispatch_data_t verified_data = dispatch_data_create(
        exact_bytes,
        library_bytes.length,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
        ^{
            std::free(exact_bytes);
        });
    if (verified_data == nil)
    {
        std::free(exact_bytes);
        mImpl->error = "cannot create immutable verified metallib data";
        return;
    }
    NSError* load_error = nil;
    id<MTLLibrary> library = [native_device newLibraryWithData:verified_data
                                                        error:&load_error];
    if (library == nil)
    {
        mImpl->error = "cannot load declared program metallib: " +
                       toString(load_error.localizedDescription);
        return;
    }

    std::set<std::string> expected_names;
    for (const MetalProgramDescriptor& descriptor : declaredMetalPrograms())
    {
        expected_names.emplace(descriptor.vertexFunction);
        expected_names.emplace(descriptor.fragmentFunction);
    }
    std::set<std::string> actual_names;
    for (NSString* function_name in library.functionNames)
    {
        actual_names.insert(toString(function_name));
    }
    if (actual_names != expected_names)
    {
        mImpl->error = "declared program metallib function set is incomplete or unexpected";
        return;
    }

    NSMutableArray<id<MTLFunction>>* functions =
        [NSMutableArray arrayWithCapacity:expected_names.size()];
    for (const MetalProgramDescriptor& descriptor : declaredMetalPrograms())
    {
        NSString* vertex_name = toNSString(descriptor.vertexFunction);
        NSString* fragment_name = toNSString(descriptor.fragmentFunction);
        id<MTLFunction> vertex =
            vertex_name == nil ? nil : [library newFunctionWithName:vertex_name];
        id<MTLFunction> fragment =
            fragment_name == nil ? nil : [library newFunctionWithName:fragment_name];
        if (vertex == nil || fragment == nil ||
            vertex.functionType != MTLFunctionTypeVertex ||
            fragment.functionType != MTLFunctionTypeFragment)
        {
            mImpl->error = "declared metallib entry point is missing or has the wrong stage: " +
                           std::string(descriptor.name);
            return;
        }
        [functions addObject:vertex];
        [functions addObject:fragment];
    }

    mImpl->device = native_device;
    mImpl->library = library;
    mImpl->functions = functions;
}

MetalProgramLibrary::~MetalProgramLibrary() = default;

bool MetalProgramLibrary::valid() const noexcept
{
    return mImpl != nullptr && mImpl->library != nil && mImpl->error.empty();
}

const std::string& MetalProgramLibrary::error() const noexcept
{
    static const std::string empty;
    return mImpl == nullptr ? empty : mImpl->error;
}

MetalProgramLibraryHandle MetalProgramLibrary::nativeLibrary() const noexcept
{
    return valid() ? (__bridge void*)mImpl->library : nullptr;
}

const MetalProgramDescriptor* MetalProgramLibrary::program(MetalProgramId id) const noexcept
{
    return valid() ? metalProgramDescriptor(id) : nullptr;
}

const MetalProgramDescriptor* MetalProgramLibrary::program(std::string_view id) const noexcept
{
    return valid() ? metalProgramDescriptor(id) : nullptr;
}

const MetalProgramDescriptor* MetalProgramLibrary::program(
    std::string_view source_symbol,
    std::optional<std::uint16_t> source_index,
    std::uint8_t shader_class) const noexcept
{
    return valid()
               ? metalProgramDescriptor(source_symbol, source_index, shader_class)
               : nullptr;
}

} // namespace firestorm::metal
