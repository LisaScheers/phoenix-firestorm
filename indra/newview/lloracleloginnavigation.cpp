/**
 * @file lloracleloginnavigation.cpp
 * @brief Developer-only receipt for the deterministic oracle login fixture.
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

#include "lloracleloginnavigation.h"

#include "lluriparser.h"

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace
{

constexpr char EXPECTED_LOGIN_PAGE[] =
    "http://127.0.0.1:19472/login_ui/index.html";

const std::string RECEIPT_DOCUMENT =
    "{\n"
    "  \"schema\": 1,\n"
    "  \"kind\": \"firestorm-opengl-oracle-login-navigation\",\n"
    "  \"configured_login_page\": \"http://127.0.0.1:19472/login_ui/index.html\",\n"
    "  \"observed_endpoint\": \"http://127.0.0.1:19472/login_ui/index.html\",\n"
    "  \"navigation_complete\": true,\n"
    "  \"http_status\": 200,\n"
    "  \"admissible\": false,\n"
    "  \"status\": \"inadmissible\",\n"
    "  \"reason\": \"Navigation completion is not capture evidence and proves neither body, hash, nor pixels.\"\n"
    "}\n";

#if defined(LL_TEST_lloracleloginnavigation)
std::mutex sPublicationHookMutex;
LLOpenGLOracleLoginNavigation::PublicationTestHook sPublicationTestHook = nullptr;

void invokePublicationTestHook()
{
    LLOpenGLOracleLoginNavigation::PublicationTestHook hook;
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

bool splitSafeOutputTarget(
    const std::string& target_path,
    std::vector<std::string>& ancestor_components,
    std::string& filename)
{
    if (target_path.size() < 2 || target_path.front() != '/' || target_path.back() == '/')
    {
        return false;
    }

    std::vector<std::string> components;
    std::string::size_type component_start = 1;
    while (component_start < target_path.size())
    {
        const std::string::size_type component_end = target_path.find('/', component_start);
        const std::string component = target_path.substr(
            component_start,
            component_end == std::string::npos ? std::string::npos : component_end - component_start);
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
        const int child_fd = ::openat(
            directory_fd, component.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
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
        const std::string staging_name =
            ".lloracleloginnavigation." + std::to_string(::arc4random()) + "." +
            std::to_string(::arc4random());
        const int descriptor = ::openat(
            directory_fd,
            staging_name.c_str(),
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0600);
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

bool publishReceipt(const std::string& target_path)
{
    std::vector<std::string> ancestor_components;
    std::string filename;
    if (!splitSafeOutputTarget(target_path, ancestor_components, filename))
    {
        return false;
    }

    const int directory_fd = openOutputDirectory(ancestor_components);
    if (directory_fd < 0)
    {
        return false;
    }

#if defined(LL_TEST_lloracleloginnavigation)
    invokePublicationTestHook();
#endif

    const int descriptor = createUnlinkedStagingFile(directory_fd);
    if (descriptor < 0)
    {
        ::close(directory_fd);
        return false;
    }

    const bool written = writeAll(
        descriptor, RECEIPT_DOCUMENT.data(), RECEIPT_DOCUMENT.size());
    const bool synchronized = written && ::fsync(descriptor) == 0;
#if defined(LL_TEST_lloracleloginnavigation)
    if (synchronized)
    {
        invokePublicationTestHook();
    }
#endif
    // The source has no remaining pathname: publish only the synchronized
    // descriptor through Darwin's no-replace clone operation. The leaf must
    // not be resolved through an existing symlink.
    const bool published = synchronized &&
        ::fclonefileat(descriptor, directory_fd, filename.c_str(), CLONE_NOFOLLOW) == 0;
    ::close(descriptor);
    ::close(directory_fd);
    return published;
}

bool hasExpectedNavigationURI(const std::string& navigation_uri)
{
    if (navigation_uri.compare(0, std::strlen(EXPECTED_LOGIN_PAGE), EXPECTED_LOGIN_PAGE) != 0 ||
        navigation_uri.find('#') != std::string::npos)
    {
        return false;
    }

    const std::string suffix = navigation_uri.substr(std::strlen(EXPECTED_LOGIN_PAGE));
    if (!suffix.empty() && suffix.front() != '?')
    {
        return false;
    }

    LLUriParser parsed_uri(navigation_uri);
    if (!parsed_uri.getLastRes())
    {
        return false;
    }
    parsed_uri.extractParts();
    return parsed_uri.scheme() == "http" &&
        parsed_uri.host() == "127.0.0.1" &&
        parsed_uri.port() == "19472" &&
        parsed_uri.path() == "/login_ui/index.html" &&
        parsed_uri.fragment().empty();
}

} // anonymous namespace

namespace LLOpenGLOracleLoginNavigation
{

bool hasExpectedLoginSettings(const std::string& login_page, const std::string& force_login_url)
{
    return login_page == EXPECTED_LOGIN_PAGE && force_login_url.empty();
}

bool isEligibleCompletion(const Completion& completion)
{
    return hasExpectedLoginSettings(completion.login_page, completion.force_login_url) &&
        completion.navigation_result_code == 200 &&
        hasExpectedNavigationURI(completion.navigation_uri);
}

const std::string& receiptDocument()
{
    return RECEIPT_DOCUMENT;
}

#if defined(LL_TEST_lloracleloginnavigation)
void setPublicationTestHook(PublicationTestHook hook)
{
    std::lock_guard<std::mutex> lock(sPublicationHookMutex);
    sPublicationTestHook = hook;
}
#endif

bool ReceiptRecorder::observe(const Event event, const Completion& completion)
{
    {
        std::lock_guard<std::mutex> lock(mMutex);
        if (event != Event::NavigationComplete || mCompletionConsumed)
        {
            return false;
        }
        mCompletionConsumed = true;
    }

    return isEligibleCompletion(completion) && publishReceipt(completion.receipt_path);
}

bool ReceiptRecorder::hasConsumedCompletion() const
{
    std::lock_guard<std::mutex> lock(mMutex);
    return mCompletionConsumed;
}

bool observeNavigationCompletion(const Completion& completion)
{
    static ReceiptRecorder recorder;
    return recorder.observe(Event::NavigationComplete, completion);
}

} // namespace LLOpenGLOracleLoginNavigation
