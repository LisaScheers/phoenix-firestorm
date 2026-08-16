/**
 * @file lloracleloginnavigation.h
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

#ifndef LL_LLORACLELOGINNAVIGATION_H
#define LL_LLORACLELOGINNAVIGATION_H

#include <mutex>
#include <string>

#if defined(LL_TEST_lloracleloginnavigation)
#include "lloraclereceiptpublisher.h"
#endif

namespace LLOpenGLOracleLoginNavigation
{

enum class Event
{
    Other,
    NavigationComplete
};

struct Completion
{
    std::string login_page;
    std::string force_login_url;
    std::string navigation_uri;
    int navigation_result_code;
    std::string receipt_path;
};

// This check deliberately has no viewer or file-system side effects so it can
// be exercised independently of the CEF-backed login control.
bool hasExpectedLoginSettings(const std::string& login_page, const std::string& force_login_url);
bool isEligibleCompletion(const Completion& completion);

const std::string& receiptDocument();

#if defined(LL_TEST_lloracleloginnavigation)
// Allows the standalone helper test to inspect the descriptor-anchored
// publication before its final clone. This is absent from viewer builds.
using PublicationTestHook = LLOpenGLOracleReceiptPublisher::PublicationTestHook;
void setPublicationTestHook(PublicationTestHook hook);
#endif

class ReceiptRecorder
{
public:
    bool observe(Event event, const Completion& completion);
    bool hasConsumedCompletion() const;

private:
    mutable std::mutex mMutex;
    bool mCompletionConsumed = false;
};

// The production observer uses one mutex-protected recorder for the whole
// process. A failed first navigation completion is therefore final and cannot
// be followed by a later successful receipt.
bool observeNavigationCompletion(const Completion& completion);

} // namespace LLOpenGLOracleLoginNavigation

#endif // LL_LLORACLELOGINNAVIGATION_H
