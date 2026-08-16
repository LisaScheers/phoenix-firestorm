/**
 * @file lloracleloginnavigation_test.cpp
 * @brief Tests the developer-only oracle login navigation receipt helper.
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

#include "../lloracleloginnavigation.h"
#include "../test/lltut.h"

#include <dirent.h>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace
{

const char EXPECTED_LOGIN_PAGE[] =
    "http://127.0.0.1:19472/login_ui/index.html";

class TemporaryReceiptPath
{
public:
    TemporaryReceiptPath()
    {
        char template_path[] = "/private/tmp/lloracleloginnavigation.XXXXXX";
        const int descriptor = ::mkstemp(template_path);
        if (descriptor < 0)
        {
            throw std::runtime_error("could not allocate a temporary receipt path");
        }
        if (::close(descriptor) != 0 || ::unlink(template_path) != 0)
        {
            ::unlink(template_path);
            throw std::runtime_error("could not prepare a temporary receipt path");
        }
        mPath = template_path;
    }

    ~TemporaryReceiptPath()
    {
        if (!mPath.empty())
        {
            ::unlink(mPath.c_str());
        }
    }

    const std::string& path() const
    {
        return mPath;
    }

private:
    std::string mPath;
};

class TemporaryDirectory
{
public:
    TemporaryDirectory()
    {
        char template_path[] = "/private/tmp/lloracleloginnavigation-dir.XXXXXX";
        char* const directory_path = ::mkdtemp(template_path);
        if (!directory_path)
        {
            throw std::runtime_error("could not allocate a temporary directory");
        }
        mPath = directory_path;
    }

    ~TemporaryDirectory()
    {
        DIR* const directory = ::opendir(mPath.c_str());
        if (directory)
        {
            while (const dirent* const entry = ::readdir(directory))
            {
                const std::string name(entry->d_name);
                if (name == "." || name == "..")
                {
                    continue;
                }
                const std::string child = mPath + "/" + name;
                struct stat status;
                if (::lstat(child.c_str(), &status) == 0 && S_ISDIR(status.st_mode) &&
                    !S_ISLNK(status.st_mode))
                {
                    ::rmdir(child.c_str());
                }
                else
                {
                    ::unlink(child.c_str());
                }
            }
            ::closedir(directory);
        }
        ::rmdir(mPath.c_str());
    }

    const std::string& path() const
    {
        return mPath;
    }

private:
    std::string mPath;
};

#if defined(LL_TEST_lloracleloginnavigation)
class OutputAncestorSwap
{
public:
    OutputAncestorSwap(
        const std::string& original_parent,
        const std::string& moved_parent,
        const std::string& replacement_parent)
    : mOriginalParent(original_parent),
      mMovedParent(moved_parent),
      mReplacementParent(replacement_parent)
    {
        sActiveSwap = this;
    }

    ~OutputAncestorSwap()
    {
        if (sActiveSwap == this)
        {
            sActiveSwap = nullptr;
        }
        ::unlink((mMovedParent + "/receipt.json").c_str());
        ::unlink((mReplacementParent + "/receipt.json").c_str());
        ::unlink(mOriginalParent.c_str());
        ::rmdir(mOriginalParent.c_str());
        ::rmdir(mMovedParent.c_str());
        ::rmdir(mReplacementParent.c_str());
    }

    static void swap()
    {
        if (sActiveSwap)
        {
            sActiveSwap->perform();
        }
    }

    bool succeeded() const
    {
        return mSucceeded;
    }

private:
    void perform()
    {
        if (mTriggered)
        {
            return;
        }
        mTriggered = true;
        mSucceeded = ::rename(mOriginalParent.c_str(), mMovedParent.c_str()) == 0 &&
            ::symlink(mReplacementParent.c_str(), mOriginalParent.c_str()) == 0;
    }

    static OutputAncestorSwap* sActiveSwap;
    std::string mOriginalParent;
    std::string mMovedParent;
    std::string mReplacementParent;
    bool mTriggered = false;
    bool mSucceeded = false;
};

OutputAncestorSwap* OutputAncestorSwap::sActiveSwap = nullptr;

class ScopedPublicationTestHook
{
public:
    explicit ScopedPublicationTestHook(
        LLOpenGLOracleLoginNavigation::PublicationTestHook hook)
    {
        LLOpenGLOracleLoginNavigation::setPublicationTestHook(hook);
    }

    ~ScopedPublicationTestHook()
    {
        LLOpenGLOracleLoginNavigation::setPublicationTestHook(nullptr);
    }
};

class FinalLeafAbsenceProbe
{
public:
    explicit FinalLeafAbsenceProbe(const std::string& final_path)
    : mFinalPath(final_path)
    {
        sActiveProbe = this;
    }

    ~FinalLeafAbsenceProbe()
    {
        if (sActiveProbe == this)
        {
            sActiveProbe = nullptr;
        }
    }

    static void inspect()
    {
        if (sActiveProbe)
        {
            sActiveProbe->record();
        }
    }

    unsigned int invocationCount() const
    {
        return mInvocationCount;
    }

    bool wasAlwaysAbsent() const
    {
        return mWasAlwaysAbsent;
    }

private:
    void record()
    {
        ++mInvocationCount;
        mWasAlwaysAbsent = mWasAlwaysAbsent && ::access(mFinalPath.c_str(), F_OK) != 0;
    }

    static FinalLeafAbsenceProbe* sActiveProbe;
    std::string mFinalPath;
    unsigned int mInvocationCount = 0;
    bool mWasAlwaysAbsent = true;
};

FinalLeafAbsenceProbe* FinalLeafAbsenceProbe::sActiveProbe = nullptr;
#endif

LLOpenGLOracleLoginNavigation::Completion eligibleCompletion(const std::string& receipt_path)
{
    return {EXPECTED_LOGIN_PAGE, "", EXPECTED_LOGIN_PAGE, 200, receipt_path};
}

std::string readFile(const std::string& path)
{
    std::ifstream input(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

} // anonymous namespace

namespace tut
{

struct oracle_login_navigation_test
{
};

typedef test_group<oracle_login_navigation_test> oracle_login_navigation_test_factory;
typedef oracle_login_navigation_test_factory::object oracle_login_navigation_test_object;
tut::oracle_login_navigation_test_factory oracle_login_navigation_tut(
    "LLOpenGLOracleLoginNavigation");

template<> template<>
void oracle_login_navigation_test_object::test<1>()
{
    LLOpenGLOracleLoginNavigation::Completion completion = eligibleCompletion("");
    ensure("the exact fixture navigation is eligible",
           LLOpenGLOracleLoginNavigation::isEligibleCompletion(completion));

    completion.navigation_uri += "?lang=en&channel=Firestorm";
    ensure("the fixture navigation accepts a query",
           LLOpenGLOracleLoginNavigation::isEligibleCompletion(completion));

    completion.navigation_uri += "#fragment";
    ensure("a navigation fragment is rejected",
           !LLOpenGLOracleLoginNavigation::isEligibleCompletion(completion));
}

template<> template<>
void oracle_login_navigation_test_object::test<2>()
{
    LLOpenGLOracleLoginNavigation::Completion completion = eligibleCompletion("");
    ensure("the pinned settings enable registration",
           LLOpenGLOracleLoginNavigation::hasExpectedLoginSettings(
               completion.login_page, completion.force_login_url));
    completion.login_page += "?unexpected=true";
    ensure("LoginPage must match exactly",
           !LLOpenGLOracleLoginNavigation::isEligibleCompletion(completion));
    ensure("a modified LoginPage disables registration",
           !LLOpenGLOracleLoginNavigation::hasExpectedLoginSettings(
               completion.login_page, completion.force_login_url));

    completion = eligibleCompletion("");
    completion.force_login_url = EXPECTED_LOGIN_PAGE;
    ensure("ForceLoginURL must remain empty",
           !LLOpenGLOracleLoginNavigation::isEligibleCompletion(completion));
    ensure("ForceLoginURL disables registration",
           !LLOpenGLOracleLoginNavigation::hasExpectedLoginSettings(
               completion.login_page, completion.force_login_url));

    completion = eligibleCompletion("");
    completion.navigation_result_code = 201;
    ensure("only HTTP 200 is accepted",
           !LLOpenGLOracleLoginNavigation::isEligibleCompletion(completion));

    const std::vector<std::string> invalid_uris = {
        "https://127.0.0.1:19472/login_ui/index.html",
        "http://localhost:19472/login_ui/index.html",
        "http://127.0.0.1:19473/login_ui/index.html",
        "http://127.0.0.1:19472/login_ui/../login_ui/index.html",
        "http://127.0.0.1:19472/login_ui/index.html/"};
    for (const std::string& uri : invalid_uris)
    {
        completion = eligibleCompletion("");
        completion.navigation_uri = uri;
        ensure("the navigation endpoint must match exactly",
               !LLOpenGLOracleLoginNavigation::isEligibleCompletion(completion));
    }
}

template<> template<>
void oracle_login_navigation_test_object::test<3>()
{
    TemporaryReceiptPath receipt_path;
    LLOpenGLOracleLoginNavigation::ReceiptRecorder recorder;
    const LLOpenGLOracleLoginNavigation::Completion completion =
        eligibleCompletion(receipt_path.path());

    ensure("other media events are ignored",
           !recorder.observe(LLOpenGLOracleLoginNavigation::Event::Other, completion));
    ensure("an ignored event does not consume the one-shot",
           !recorder.hasConsumedCompletion());

    LLOpenGLOracleLoginNavigation::Completion rejected = completion;
    rejected.navigation_result_code = 404;
    ensure("the first bad completion is rejected",
           !recorder.observe(LLOpenGLOracleLoginNavigation::Event::NavigationComplete, rejected));
    ensure("the first completion consumes the one-shot",
           recorder.hasConsumedCompletion());
    ensure("a later good completion cannot recover the receipt",
           !recorder.observe(LLOpenGLOracleLoginNavigation::Event::NavigationComplete, completion));
    ensure("a rejected first completion writes nothing", ::access(receipt_path.path().c_str(), F_OK) != 0);
}

template<> template<>
void oracle_login_navigation_test_object::test<4>()
{
    TemporaryReceiptPath receipt_path;
    const LLOpenGLOracleLoginNavigation::Completion completion =
        eligibleCompletion(receipt_path.path());
    LLOpenGLOracleLoginNavigation::ReceiptRecorder recorder;

    ensure("the first eligible completion publishes a receipt",
           recorder.observe(LLOpenGLOracleLoginNavigation::Event::NavigationComplete, completion));
    const std::string receipt = readFile(receipt_path.path());
    ensure_equals("the receipt document is complete", receipt,
                  LLOpenGLOracleLoginNavigation::receiptDocument());
    ensure_contains("the receipt declares schema one", receipt,
                    "\"schema\": 1");
    ensure_contains("the receipt identifies its kind", receipt,
                    "\"kind\": \"firestorm-opengl-oracle-login-navigation\"");
    ensure_contains("the receipt remains inadmissible", receipt,
                    "\"admissible\": false");
    ensure_contains("the receipt declares inadmissible status", receipt,
                    "\"status\": \"inadmissible\"");
    ensure_contains("the receipt says navigation is not capture evidence", receipt,
                    "Navigation completion is not capture evidence");
    ensure_contains("the receipt records the configured LoginPage", receipt,
                    "\"configured_login_page\": \"http://127.0.0.1:19472/login_ui/index.html\"");
    ensure_contains("the receipt records the canonical observed endpoint", receipt,
                    "\"observed_endpoint\": \"http://127.0.0.1:19472/login_ui/index.html\"");
    ensure_contains("the receipt records navigation completion", receipt,
                    "\"navigation_complete\": true");
    ensure_contains("the receipt records HTTP status 200", receipt,
                    "\"http_status\": 200");
    ensure_contains("the receipt does not claim body or pixel evidence", receipt,
                    "proves neither body, hash, nor pixels");
    ensure("a duplicate event cannot publish again",
           !recorder.observe(LLOpenGLOracleLoginNavigation::Event::NavigationComplete, completion));
    ensure_equals("the duplicate event leaves the receipt unchanged", readFile(receipt_path.path()), receipt);

    LLOpenGLOracleLoginNavigation::ReceiptRecorder replacement_recorder;
    ensure("an existing receipt is never replaced",
           !replacement_recorder.observe(
               LLOpenGLOracleLoginNavigation::Event::NavigationComplete, completion));
    ensure_equals("the existing receipt is still unchanged", readFile(receipt_path.path()), receipt);
}

template<> template<>
void oracle_login_navigation_test_object::test<5>()
{
    TemporaryReceiptPath existing_path;
    {
        std::ofstream existing(existing_path.path(), std::ios::binary);
        existing << "keep-existing-receipt";
    }

    LLOpenGLOracleLoginNavigation::ReceiptRecorder recorder;
    ensure("an existing output path is refused",
           !recorder.observe(
               LLOpenGLOracleLoginNavigation::Event::NavigationComplete,
               eligibleCompletion(existing_path.path())));
    ensure_equals("an existing file is not overwritten", readFile(existing_path.path()),
                  std::string("keep-existing-receipt"));

    LLOpenGLOracleLoginNavigation::ReceiptRecorder relative_path_recorder;
    ensure("a relative output path is refused",
           !relative_path_recorder.observe(
               LLOpenGLOracleLoginNavigation::Event::NavigationComplete,
               eligibleCompletion("oracle-login-navigation.json")));

    TemporaryDirectory final_symlink_directory;
    const std::string final_symlink_path = final_symlink_directory.path() + "/receipt.json";
    const std::string final_symlink_target = final_symlink_directory.path() + "/redirected.json";
    ensure("a final output symlink is created",
           ::symlink(final_symlink_target.c_str(), final_symlink_path.c_str()) == 0);
    LLOpenGLOracleLoginNavigation::ReceiptRecorder final_symlink_recorder;
    ensure("a final output symlink is refused",
           !final_symlink_recorder.observe(
               LLOpenGLOracleLoginNavigation::Event::NavigationComplete,
               eligibleCompletion(final_symlink_path)));
    ensure("the final symlink target receives no receipt",
           ::access(final_symlink_target.c_str(), F_OK) != 0);

#ifdef LL_DARWIN
    TemporaryReceiptPath canonical_tmp_path;
    const std::string::size_type filename_start =
        canonical_tmp_path.path().find_last_of('/') + 1;
    const std::string tmp_symlink_path =
        "/tmp/" + canonical_tmp_path.path().substr(filename_start);
    LLOpenGLOracleLoginNavigation::ReceiptRecorder tmp_symlink_recorder;
    ensure("the macOS /tmp symlink route is refused",
           !tmp_symlink_recorder.observe(
               LLOpenGLOracleLoginNavigation::Event::NavigationComplete,
               eligibleCompletion(tmp_symlink_path)));
    ensure("the canonical /private/tmp target receives no receipt",
           ::access(canonical_tmp_path.path().c_str(), F_OK) != 0);
#endif

    TemporaryDirectory directory;
    const std::string real_parent = directory.path() + "/real";
    const std::string real_child = real_parent + "/nested";
    const std::string linked_parent = directory.path() + "/linked";
    ensure("the real output parent is created", ::mkdir(real_parent.c_str(), 0700) == 0);
    ensure("the nested real output parent is created", ::mkdir(real_child.c_str(), 0700) == 0);
    ensure("a symlinked output ancestor is created", ::symlink(real_parent.c_str(), linked_parent.c_str()) == 0);

    LLOpenGLOracleLoginNavigation::ReceiptRecorder symlink_recorder;
    ensure("a symlinked output ancestor is refused",
           !symlink_recorder.observe(
               LLOpenGLOracleLoginNavigation::Event::NavigationComplete,
               eligibleCompletion(linked_parent + "/nested/receipt.json")));
    ensure("the symlinked parent receives no receipt",
           ::access((real_child + "/receipt.json").c_str(), F_OK) != 0);
    ::rmdir(real_child.c_str());
}

#if defined(LL_TEST_lloracleloginnavigation)
template<> template<>
void oracle_login_navigation_test_object::test<6>()
{
    TemporaryDirectory directory;
    const std::string original_parent = directory.path() + "/original";
    const std::string moved_parent = directory.path() + "/moved";
    const std::string replacement_parent = directory.path() + "/replacement";
    ensure("the output parent is created", ::mkdir(original_parent.c_str(), 0700) == 0);
    ensure("the replacement parent is created", ::mkdir(replacement_parent.c_str(), 0700) == 0);

    OutputAncestorSwap ancestor_swap(original_parent, moved_parent, replacement_parent);
    ScopedPublicationTestHook publication_hook(&OutputAncestorSwap::swap);
    LLOpenGLOracleLoginNavigation::ReceiptRecorder recorder;
    ensure("an ancestor replacement after traversal still publishes the receipt",
           recorder.observe(
               LLOpenGLOracleLoginNavigation::Event::NavigationComplete,
               eligibleCompletion(original_parent + "/receipt.json")));
    ensure("the deterministic ancestor swap ran", ancestor_swap.succeeded());
    ensure_equals("the retained directory descriptor receives the receipt",
                  readFile(moved_parent + "/receipt.json"),
                  LLOpenGLOracleLoginNavigation::receiptDocument());
    ensure("the replacement symlink target receives no receipt",
           ::access((replacement_parent + "/receipt.json").c_str(), F_OK) != 0);
}
#endif

#if defined(LL_TEST_lloracleloginnavigation)
template<> template<>
void oracle_login_navigation_test_object::test<7>()
{
    TemporaryReceiptPath receipt_path;
    FinalLeafAbsenceProbe final_leaf_probe(receipt_path.path());
    ScopedPublicationTestHook publication_hook(&FinalLeafAbsenceProbe::inspect);
    LLOpenGLOracleLoginNavigation::ReceiptRecorder recorder;

    ensure("the unlinked staging descriptor is cloneable into the final leaf",
           recorder.observe(
               LLOpenGLOracleLoginNavigation::Event::NavigationComplete,
               eligibleCompletion(receipt_path.path())));
    ensure_equals("publication reaches both pre-clone inspection points",
                  final_leaf_probe.invocationCount(), 2U);
    ensure("the final leaf stays absent until clone publication",
           final_leaf_probe.wasAlwaysAbsent());
    ensure_equals("the final clone has the complete receipt", readFile(receipt_path.path()),
                  LLOpenGLOracleLoginNavigation::receiptDocument());
}
#endif

} // namespace tut
