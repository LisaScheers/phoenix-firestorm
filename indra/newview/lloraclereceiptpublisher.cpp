/**
 * @file lloraclereceiptpublisher.cpp
 * @brief Darwin no-replace publisher for developer-only OpenGL oracle receipts.
 *
 * $LicenseInfo:firstyear=2026&license=viewerlgpl$
 * Second Life Viewer Source Code
 * Copyright (C) 2026, Linden Research, Inc.
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

#include "linden_common.h"

#include "lloraclereceiptpublisher.h"

#include <cerrno>
#include <fcntl.h>
#include <mutex>
#include <stdlib.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace
{

#if defined(LL_TEST_lloracleloginnavigation) || defined(LL_TEST_lloracleloginvisualprofile)
std::mutex                                          sPublicationHookMutex;
LLOpenGLOracleReceiptPublisher::PublicationTestHook sPublicationTestHook = nullptr;

void invokePublicationTestHook()
{
    LLOpenGLOracleReceiptPublisher::PublicationTestHook hook;
    {
        std::lock_guard<std::mutex> lock(sPublicationHookMutex);
        hook = sPublicationTestHook;
    }
    if (hook)
    {
        hook();
    }
}
#endif

bool splitSafeOutputTarget(const std::string& target_path, std::vector<std::string>& ancestor_components, std::string& filename)
{
    if (target_path.size() < 2 || target_path.front() != '/' || target_path.back() == '/')
    {
        return false;
    }

    std::vector<std::string> components;
    std::string::size_type   component_start = 1;
    while (component_start < target_path.size())
    {
        const std::string::size_type component_end = target_path.find('/', component_start);
        const std::string            component =
            target_path.substr(component_start, component_end == std::string::npos ? std::string::npos : component_end - component_start);
        if (component.empty() || component == "." || component == "..")
        {
            return false;
        }

        if (component_end == std::string::npos)
        {
            components.push_back(component);
            break;
        }
        components.push_back(component);
        component_start = component_end + 1;
    }

    if (components.empty())
    {
        return false;
    }

    filename = components.back();
    components.pop_back();
    ancestor_components = components;
    return true;
}

bool isDirectoryDescriptor(const int descriptor)
{
    struct stat status;
    return ::fstat(descriptor, &status) == 0 && S_ISDIR(status.st_mode);
}

int openOutputDirectory(const std::vector<std::string>& ancestor_components)
{
    int directory_fd = ::open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory_fd < 0 || !isDirectoryDescriptor(directory_fd))
    {
        if (directory_fd >= 0)
        {
            ::close(directory_fd);
        }
        return -1;
    }

    for (const std::string& component : ancestor_components)
    {
        const int child_fd = ::openat(directory_fd, component.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        ::close(directory_fd);
        if (child_fd < 0 || !isDirectoryDescriptor(child_fd))
        {
            if (child_fd >= 0)
            {
                ::close(child_fd);
            }
            return -1;
        }
        directory_fd = child_fd;
    }

    return directory_fd;
}

int createUnlinkedStagingFile(const int directory_fd)
{
    constexpr unsigned int MAX_STAGING_ATTEMPTS = 128;
    for (unsigned int attempt = 0; attempt < MAX_STAGING_ATTEMPTS; ++attempt)
    {
        const std::string staging_name = ".lloraclereceipt." + std::to_string(::arc4random()) + "." + std::to_string(::arc4random());
        const int descriptor = ::openat(directory_fd, staging_name.c_str(), O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (descriptor < 0)
        {
            if (errno == EEXIST || errno == EINTR)
            {
                continue;
            }
            return -1;
        }

        if (::unlinkat(directory_fd, staging_name.c_str(), 0) == 0 || errno == ENOENT)
        {
            return descriptor;
        }

        ::close(descriptor);
        return -1;
    }

    return -1;
}

bool writeAll(const int descriptor, const char* data, std::size_t remaining)
{
    while (remaining > 0)
    {
        const ssize_t written = ::write(descriptor, data, remaining);
        if (written > 0)
        {
            data += written;
            remaining -= static_cast<std::size_t>(written);
            continue;
        }
        if (written < 0 && errno == EINTR)
        {
            continue;
        }
        return false;
    }
    return true;
}

} // anonymous namespace

namespace LLOpenGLOracleReceiptPublisher
{

bool publishNoReplace(const std::string& target_path, const std::string& document)
{
    std::vector<std::string> ancestor_components;
    std::string              filename;
    if (!splitSafeOutputTarget(target_path, ancestor_components, filename))
    {
        return false;
    }

    const int directory_fd = openOutputDirectory(ancestor_components);
    if (directory_fd < 0)
    {
        return false;
    }

#if defined(LL_TEST_lloracleloginnavigation) || defined(LL_TEST_lloracleloginvisualprofile)
    invokePublicationTestHook();
#endif

    const int descriptor = createUnlinkedStagingFile(directory_fd);
    if (descriptor < 0)
    {
        ::close(directory_fd);
        return false;
    }

    const bool written      = writeAll(descriptor, document.data(), document.size());
    const bool synchronized = written && ::fsync(descriptor) == 0;
#if defined(LL_TEST_lloracleloginnavigation) || defined(LL_TEST_lloracleloginvisualprofile)
    if (synchronized)
    {
        invokePublicationTestHook();
    }
#endif
    // The source has no remaining pathname. Publish only from the synchronized
    // descriptor to an absent destination leaf. An existing leaf, including a
    // symlink, is neither replaced nor resolved.
    const bool published = synchronized && ::fclonefileat(descriptor, directory_fd, filename.c_str(), CLONE_NOFOLLOW) == 0;
    ::close(descriptor);
    ::close(directory_fd);
    return published;
}

#if defined(LL_TEST_lloracleloginnavigation) || defined(LL_TEST_lloracleloginvisualprofile)
void setPublicationTestHook(PublicationTestHook hook)
{
    std::lock_guard<std::mutex> lock(sPublicationHookMutex);
    sPublicationTestHook = hook;
}
#endif

} // namespace LLOpenGLOracleReceiptPublisher
