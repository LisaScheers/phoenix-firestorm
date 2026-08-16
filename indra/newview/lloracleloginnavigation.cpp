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
#include "lloraclereceiptpublisher.h"

#include "lluriparser.h"

#include <cstring>

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

bool publishReceipt(const std::string& target_path)
{
    return LLOpenGLOracleReceiptPublisher::publishNoReplace(target_path, RECEIPT_DOCUMENT);
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
    LLOpenGLOracleReceiptPublisher::setPublicationTestHook(hook);
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
