/**
 * @file lloracleloginvisualprofile_test.cpp
 * @brief Tests the developer-only OpenGL oracle login visual-profile preflight.
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

#include "../lloracleloginvisualprofile.h"
#include "../lloraclereceiptpublisher.h"
#include "../test/lltut.h"

#include <boost/json.hpp>

#include <dirent.h>
#include <fstream>
#include <functional>
#include <iterator>
#include <set>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
#include <vector>

namespace
{

namespace LoginVisualProfile = LLOpenGLOracleLoginVisualProfile;

LoginVisualProfile::Rect makeRect(const int left, const int bottom, const int right, const int top)
{
    LoginVisualProfile::Rect rect;
    rect.left   = left;
    rect.bottom = bottom;
    rect.right  = right;
    rect.top    = top;
    return rect;
}

void removeTree(const std::string& path)
{
    struct stat status;
    if (::lstat(path.c_str(), &status) != 0)
    {
        return;
    }

    if (!S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode))
    {
        ::unlink(path.c_str());
        return;
    }

    DIR* const directory = ::opendir(path.c_str());
    if (!directory)
    {
        return;
    }
    while (const dirent* const entry = ::readdir(directory))
    {
        const std::string name(entry->d_name);
        if (name != "." && name != "..")
        {
            removeTree(path + "/" + name);
        }
    }
    ::closedir(directory);
    ::rmdir(path.c_str());
}

class TemporaryReceiptPath
{
public:
    TemporaryReceiptPath()
    {
        char      template_path[] = "/private/tmp/lloracleloginvisualprofile.XXXXXX";
        const int descriptor      = ::mkstemp(template_path);
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

    const std::string& path() const { return mPath; }

private:
    std::string mPath;
};

class TemporaryDirectory
{
public:
    TemporaryDirectory()
    {
        char        template_path[] = "/private/tmp/lloracleloginvisualprofile-dir.XXXXXX";
        char* const directory_path  = ::mkdtemp(template_path);
        if (!directory_path)
        {
            throw std::runtime_error("could not allocate a temporary directory");
        }
        mPath = directory_path;
    }

    ~TemporaryDirectory() { removeTree(mPath); }

    const std::string& path() const { return mPath; }

private:
    std::string mPath;
};

#if defined(LL_TEST_lloracleloginvisualprofile)
class OutputAncestorSwap
{
public:
    OutputAncestorSwap(const std::string& original_parent, const std::string& moved_parent, const std::string& replacement_parent) :
        mOriginalParent(original_parent),
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
        removeTree(mOriginalParent);
        removeTree(mMovedParent);
        removeTree(mReplacementParent);
    }

    static void swap()
    {
        if (sActiveSwap)
        {
            sActiveSwap->perform();
        }
    }

    bool succeeded() const { return mSucceeded; }

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
    std::string                mOriginalParent;
    std::string                mMovedParent;
    std::string                mReplacementParent;
    bool                       mTriggered = false;
    bool                       mSucceeded = false;
};

OutputAncestorSwap* OutputAncestorSwap::sActiveSwap = nullptr;

class ScopedPublicationTestHook
{
public:
    explicit ScopedPublicationTestHook(LLOpenGLOracleReceiptPublisher::PublicationTestHook hook)
    {
        LLOpenGLOracleReceiptPublisher::setPublicationTestHook(hook);
    }

    ~ScopedPublicationTestHook() { LLOpenGLOracleReceiptPublisher::setPublicationTestHook(nullptr); }
};

class FinalLeafAbsenceProbe
{
public:
    explicit FinalLeafAbsenceProbe(const std::string& final_path) : mFinalPath(final_path) { sActiveProbe = this; }

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

    unsigned int invocationCount() const { return mInvocationCount; }

    bool wasAlwaysAbsent() const { return mWasAlwaysAbsent; }

private:
    void record()
    {
        ++mInvocationCount;
        mWasAlwaysAbsent = mWasAlwaysAbsent && ::access(mFinalPath.c_str(), F_OK) != 0;
    }

    static FinalLeafAbsenceProbe* sActiveProbe;
    std::string                   mFinalPath;
    unsigned int                  mInvocationCount = 0;
    bool                          mWasAlwaysAbsent = true;
};

FinalLeafAbsenceProbe* FinalLeafAbsenceProbe::sActiveProbe = nullptr;
#endif

LoginVisualProfile::Snapshot eligibleSnapshot(const std::string& receipt_path)
{
    LoginVisualProfile::Snapshot snapshot;
    snapshot.configured_login.login_page            = "http://127.0.0.1:19472/login_ui/index.html";
    snapshot.configured_login.force_login_url       = "";
    snapshot.configured_login.session_settings_file = "settings_firestorm.xml";

    LoginVisualProfile::ProfileControls& controls = snapshot.profile_controls;
    controls.language                             = "en";
    controls.skin                                 = "firestorm";
    controls.skin_theme                           = "grey";
    controls.use_legacy_login_panel               = false;
    controls.font_settings_file                   = "fonts.xml";
    controls.font_size_adjustment                 = 0.0;
    controls.font_line_spacing_adjustment         = 0;
    controls.font_screen_dpi                      = 96.0;
    controls.ui_scale_factor                      = 1.0;
    controls.reset_ui_scale_on_first_run          = false;
    controls.render_hidpi                         = true;
    controls.render_performance_test              = false;
    controls.first_login_this_install             = false;
    controls.show_whitelist_reminder              = false;
    controls.updater_show_release_notes           = 0;
    controls.window_maximized                     = false;
    controls.show_start_location                  = true;
    controls.login_location                       = "last";
    controls.next_login_location                  = "last";
    controls.force_show_grid                      = false;
    controls.opensim_always_force_show_grid       = false;
    controls.remember_username                    = true;
    controls.browser_proxy_enabled                = false;
    controls.noninteractive_setting               = false;
    controls.headless_setting                     = false;
    controls.render_fsaa_samples                  = 0;
    controls.render_fsaa_type                     = 0;
    controls.render_ui_buffer                     = false;

    LoginVisualProfile::EffectiveUI& ui       = snapshot.effective_ui;
    ui.language                               = "en";
    ui.skin                                   = "firestorm";
    ui.skin_theme                             = "grey";
    ui.skin_language                          = "en";
    ui.selected_xui                           = "panel_fs_nui_login.xml";
    ui.required_controls.login_html           = true;
    ui.required_controls.username_combo       = true;
    ui.required_controls.password_edit        = true;
    ui.required_controls.start_location_combo = true;
    ui.required_controls.server_combo         = true;
    ui.required_controls.mode_combo           = true;
    ui.required_controls.start_location_panel = true;
    ui.required_controls.grid_panel           = true;

    snapshot.font_metrics.applied_horizontal_dpi = 192.0;
    snapshot.font_metrics.applied_vertical_dpi   = 192.0;
    snapshot.font_metrics.applied_scale_x        = 2.0;
    snapshot.font_metrics.applied_scale_y        = 2.0;

    LoginVisualProfile::LoginState& login        = snapshot.login_state;
    login.credential_store_count                 = 0;
    login.username_combo_item_count              = 0;
    login.username_entry_empty                   = true;
    login.password_entry_empty                   = true;
    login.favorites_present                      = false;
    login.selected_location                      = "last";
    login.start_location_selector.direct_visible = true;
    login.start_location_selector.visible_chain  = true;
    login.start_location_selector.visible_amount = 1.0;
    login.grid_selector.direct_visible           = false;
    login.grid_selector.visible_chain            = false;
    login.grid_selector.visible_amount           = 0.0;

    LoginVisualProfile::UIState& state = snapshot.ui_state;
    state.noninteractive_runtime       = false;
    state.headless_runtime             = false;
    state.modal_dialog_count           = 0;
    state.visible_notification_count   = 0;
    state.top_control_present          = false;
    state.window_visible               = true;
    state.window_minimized             = false;
    state.window_maximized             = false;
    state.window_fullscreen            = false;

    LoginVisualProfile::DisplayState& display         = snapshot.display;
    display.backing_scale                             = 2.0;
    display.ui_scale_factor                           = 1.0;
    display.display_scale_x                           = 2.0;
    display.display_scale_y                           = 2.0;
    display.pixel_aspect_ratio                        = 1.0;
    display.window_raw_px                             = makeRect(0, 0, 1920, 1080);
    display.window_scaled_ui                          = makeRect(0, 0, 960, 540);
    display.login_holder.local_ui                     = makeRect(0, 0, 960, 540);
    display.login_holder.viewer_screen_ui             = makeRect(0, 0, 960, 540);
    display.login_holder.viewer_screen_raw_px_derived = makeRect(0, 0, 1920, 1080);
    display.login_panel.local_ui                      = makeRect(0, 0, 800, 400);
    display.login_panel.viewer_screen_ui              = makeRect(50, 50, 850, 450);
    display.login_panel.viewer_screen_raw_px_derived  = makeRect(100, 100, 1700, 900);

    snapshot.receipt_path = receipt_path;
    return snapshot;
}

std::string readFile(const std::string& path)
{
    std::ifstream input(path, std::ios::binary);
    return { std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>() };
}

using SnapshotMutation = std::function<void(LoginVisualProfile::Snapshot&)>;
using NamedMutation    = std::pair<std::string, SnapshotMutation>;

void ensureExactObjectKeys(const boost::json::object& object, const std::vector<std::string>& expected_keys)
{
    std::set<std::string> actual_keys;
    for (const boost::json::key_value_pair& member : object)
    {
        actual_keys.emplace(member.key().data(), member.key().size());
    }

    tut::ensure_equals("the JSON object has no duplicate keys", actual_keys.size(), object.size());
    tut::ensure_equals("the JSON object has the expected number of keys", actual_keys.size(), expected_keys.size());
    for (const std::string& key : expected_keys)
    {
        tut::ensure("the JSON object contains each expected key", actual_keys.count(key) == 1);
    }
}

void ensureMutationsReject(const std::vector<NamedMutation>& mutations)
{
    for (const NamedMutation& mutation : mutations)
    {
        LoginVisualProfile::Snapshot snapshot = eligibleSnapshot("");
        mutation.second(snapshot);
        tut::ensure("an altered " + mutation.first + " is rejected", !LoginVisualProfile::isEligibleSnapshot(snapshot));
    }
}

} // anonymous namespace

namespace tut
{

struct oracle_login_visual_profile_test
{
};

typedef test_group<oracle_login_visual_profile_test>     oracle_login_visual_profile_test_factory;
typedef oracle_login_visual_profile_test_factory::object oracle_login_visual_profile_test_object;
tut::oracle_login_visual_profile_test_factory            oracle_login_visual_profile_tut("LLOpenGLOracleLoginVisualProfile");

template<>
template<>
void oracle_login_visual_profile_test_object::test<1>()
{
    ensure("the complete canonical profile is eligible", LoginVisualProfile::isEligibleSnapshot(eligibleSnapshot("")));

    const std::vector<NamedMutation> mutations = {
        { "LoginPage", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.configured_login.login_page += "?unexpected=true"; } },
        { "ForceLoginURL",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.configured_login.force_login_url = "https://example.invalid"; } },
        { "SessionSettingsFile",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.configured_login.session_settings_file = "settings.xml"; } },
        { "Language", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.language = "fr"; } },
        { "SkinCurrent", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.skin = "default"; } },
        { "SkinCurrentTheme", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.skin_theme = "dark"; } },
        { "FSUseLegacyLoginPanel",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.use_legacy_login_panel = true; } },
        { "FSFontSettingsFile",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.font_settings_file = "other-fonts.xml"; } },
        { "FSFontSizeAdjustment", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.font_size_adjustment = 1.0; } },
        { "FSFontLineSpacingAdjustment",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.font_line_spacing_adjustment = 1; } },
        { "FontScreenDPI", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.font_screen_dpi = 95.0; } },
        { "UIScaleFactor", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.ui_scale_factor = 1.25; } },
        { "ResetUIScaleOnFirstRun",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.reset_ui_scale_on_first_run = true; } },
        { "RenderHiDPI", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.render_hidpi = false; } },
        { "RenderPerformanceTest",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.render_performance_test = true; } },
        { "FirstLoginThisInstall",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.first_login_this_install = true; } },
        { "FSShowWhitelistReminder",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.show_whitelist_reminder = true; } },
        { "UpdaterShowReleaseNotes",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.updater_show_release_notes = 1; } },
        { "WindowMaximized", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.window_maximized = true; } },
        { "ShowStartLocation", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.show_start_location = false; } },
        { "LoginLocation", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.login_location = "home"; } },
        { "NextLoginLocation", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.next_login_location = "home"; } },
        { "ForceShowGrid", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.force_show_grid = true; } },
        { "FSOpenSimAlwaysForceShowGrid",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.opensim_always_force_show_grid = true; } },
        { "FSRememberUsername", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.remember_username = false; } },
        { "BrowserProxyEnabled", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.browser_proxy_enabled = true; } },
        { "NonInteractive", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.noninteractive_setting = true; } },
        { "HeadlessClient", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.headless_setting = true; } },
        { "RenderFSAASamples", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.render_fsaa_samples = 4; } },
        { "RenderFSAAType", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.render_fsaa_type = 1; } },
        { "RenderUIBuffer", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.profile_controls.render_ui_buffer = true; } },
    };
    ensureMutationsReject(mutations);
}

template<>
template<>
void oracle_login_visual_profile_test_object::test<2>()
{
    const std::vector<NamedMutation> mutations = {
        { "effective language", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.effective_ui.language           = "fr"; } },
        { "effective skin", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.effective_ui.skin = "default"; } },
        { "effective theme", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.effective_ui.skin_theme = "dark"; } },
        { "effective skin language", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.effective_ui.skin_language = "fr"; } },
        { "selected legacy XUI",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.effective_ui.selected_xui = "panel_fs_login.xml"; } },
        { "missing login HTML control",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.effective_ui.required_controls.login_html = false; } },
        { "missing username combo",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.effective_ui.required_controls.username_combo = false; } },
        { "missing password edit",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.effective_ui.required_controls.password_edit = false; } },
        { "missing start-location combo",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.effective_ui.required_controls.start_location_combo = false; } },
        { "missing server combo",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.effective_ui.required_controls.server_combo = false; } },
        { "missing mode combo",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.effective_ui.required_controls.mode_combo = false; } },
        { "missing start-location panel",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.effective_ui.required_controls.start_location_panel = false; } },
        { "missing grid panel",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.effective_ui.required_controls.grid_panel = false; } },
        { "horizontal font DPI", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.font_metrics.applied_horizontal_dpi = 96.0; } },
        { "vertical font DPI", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.font_metrics.applied_vertical_dpi = 96.0; } },
        { "font X scale", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.font_metrics.applied_scale_x = 1.0; } },
        { "font Y scale", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.font_metrics.applied_scale_y = 1.0; } },
        { "credential store", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.login_state.credential_store_count = 1; } },
        { "username account list", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.login_state.username_combo_item_count = 1; } },
        { "username entry", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.login_state.username_entry_empty = false; } },
        { "password entry", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.login_state.password_entry_empty = false; } },
        { "favorites", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.login_state.favorites_present = true; } },
        { "selected location", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.login_state.selected_location = "home"; } },
        { "hidden start selector",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.login_state.start_location_selector.direct_visible = false; } },
        { "partial start selector",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.login_state.start_location_selector.visible_amount = 0.5; } },
        { "visible grid selector",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.login_state.grid_selector.direct_visible = true; } },
        { "grid selector chain", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.login_state.grid_selector.visible_chain = true; } },
        { "partial grid selector",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.login_state.grid_selector.visible_amount = 0.5; } },
        { "noninteractive runtime", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.ui_state.noninteractive_runtime = true; } },
        { "headless runtime", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.ui_state.headless_runtime = true; } },
        { "modal dialog", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.ui_state.modal_dialog_count = 1; } },
        { "visible notification", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.ui_state.visible_notification_count = 1; } },
        { "top control", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.ui_state.top_control_present = true; } },
        { "hidden window", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.ui_state.window_visible = false; } },
        { "minimized window", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.ui_state.window_minimized = true; } },
        { "maximized window", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.ui_state.window_maximized = true; } },
        { "fullscreen window", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.ui_state.window_fullscreen = true; } },
        { "backing scale", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.display.backing_scale = 1.0; } },
        { "display UI scale", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.display.ui_scale_factor = 1.25; } },
        { "display X scale", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.display.display_scale_x = 1.0; } },
        { "display Y scale", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.display.display_scale_y = 1.0; } },
        { "pixel aspect", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.display.pixel_aspect_ratio = 1.1; } },
        { "raw drawable width", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.display.window_raw_px.right = 1919; } },
        { "raw drawable height", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.display.window_raw_px.top = 1079; } },
        { "scaled window width", [](LoginVisualProfile::Snapshot& snapshot) { snapshot.display.window_scaled_ui.right = 959; } },
        { "derived raw geometry",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.display.login_panel.viewer_screen_raw_px_derived.right = 1699; } },
        { "inconsistent local geometry",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.display.login_panel.local_ui.right = 799; } },
        { "panel outside holder",
          [](LoginVisualProfile::Snapshot& snapshot) { snapshot.display.login_panel.viewer_screen_ui.right = 970; } },
    };
    ensureMutationsReject(mutations);
}

template<>
template<>
void oracle_login_visual_profile_test_object::test<3>()
{
    const LoginVisualProfile::Snapshot snapshot = eligibleSnapshot("");
    const std::string                  receipt  = LoginVisualProfile::receiptDocument(snapshot);
    ensure("an eligible snapshot has a receipt document", !receipt.empty());

    const boost::json::value   document_value = boost::json::parse(receipt);
    const boost::json::object& document       = document_value.as_object();
    ensure_equals("the receipt schema is one", document.at("schema").as_int64(), 1);
    ensure_equals("the receipt identifies the visual preflight",
                  std::string(document.at("kind").as_string().c_str()),
                  std::string("firestorm-opengl-oracle-login-visual-profile"));
    ensure("the receipt is inadmissible", !document.at("admissible").as_bool());
    ensure_equals("the receipt declares inadmissible status",
                  std::string(document.at("status").as_string().c_str()),
                  std::string("inadmissible"));
    ensure("the receipt says it is not CEF body evidence",
           document.at("reason").as_string().find("CEF response body or hash") != std::string::npos);
    ensure("the receipt says it is not surface evidence",
           document.at("reason").as_string().find("CEF surface update") != std::string::npos);
    ensure("the receipt says it is not frame or pixel evidence",
           document.at("reason").as_string().find("painted or presented frame, pixels") != std::string::npos);
    ensure("the receipt says it is not capture-ready evidence",
           document.at("reason").as_string().find("capture output or readiness") != std::string::npos);
    ensure("the receipt says it is not colour or occlusion evidence",
           document.at("reason").as_string().find("sRGB color space, lack of OS occlusion") != std::string::npos);
    ensure("the receipt says it is not machine admission",
           document.at("reason").as_string().find("machine admission") != std::string::npos);
    ensure("the receipt is built under the developer capture seam", document.at("developer_capture_build").as_bool());

    const boost::json::object& controls = document.at("profile_controls").as_object();
    ensureExactObjectKeys(controls,
                          { "language",
                            "skin",
                            "skin_theme",
                            "use_legacy_login_panel",
                            "font_settings_file",
                            "font_size_adjustment",
                            "font_line_spacing_adjustment",
                            "font_screen_dpi",
                            "ui_scale_factor",
                            "reset_ui_scale_on_first_run",
                            "render_hidpi",
                            "render_performance_test",
                            "first_login_this_install",
                            "show_whitelist_reminder",
                            "updater_show_release_notes",
                            "window_maximized",
                            "show_start_location",
                            "login_location",
                            "next_login_location",
                            "force_show_grid",
                            "opensim_always_force_show_grid",
                            "remember_username",
                            "browser_proxy_enabled",
                            "noninteractive_setting",
                            "headless_setting",
                            "render_fsaa_samples",
                            "render_fsaa_type",
                            "render_ui_buffer" });
    ensure("font adjustment remains a JSON real", controls.at("font_size_adjustment").is_double());
    ensure("font DPI remains a JSON real", controls.at("font_screen_dpi").is_double());
    ensure("FSAA remains a JSON integer", controls.at("render_fsaa_samples").is_int64());
    ensure("the receipt contains no output path", document.find("receipt_path") == document.end());
    ensure("the receipt makes no colour-space claim", document.find("color_space") == document.end());
    ensure("the receipt makes no window-mode claim", document.find("window_mode") == document.end());
    ensure("the receipt makes no navigation assertion", document.find("observed_endpoint") == document.end());

    const boost::json::object& display = document.at("display").as_object();
    const boost::json::object& panel   = display.at("login_panel").as_object();
    ensure_equals("the dynamic panel geometry is recorded", panel.at("viewer_screen_ui").as_object().at("left").as_int64(), 50);
    ensure_equals("the derived raw geometry is recorded", panel.at("viewer_screen_raw_px_derived").as_object().at("right").as_int64(),
                  1700);

    LoginVisualProfile::Snapshot rejected        = snapshot;
    rejected.ui_state.visible_notification_count = 1;
    ensure("an ineligible snapshot cannot be serialized", LoginVisualProfile::receiptDocument(rejected).empty());
}

template<>
template<>
void oracle_login_visual_profile_test_object::test<4>()
{
    TemporaryReceiptPath                receipt_path;
    LoginVisualProfile::Snapshot        completion = eligibleSnapshot(receipt_path.path());
    LoginVisualProfile::ReceiptRecorder recorder;

    LoginVisualProfile::Snapshot rejected             = completion;
    rejected.profile_controls.show_whitelist_reminder = true;
    ensure("the first ineligible settled snapshot is refused", !recorder.observe(rejected));
    ensure("the first settled snapshot consumes the one-shot", recorder.hasConsumedSnapshot());
    ensure("a later eligible snapshot cannot recover the receipt", !recorder.observe(completion));
    ensure("the rejected first snapshot writes nothing", ::access(receipt_path.path().c_str(), F_OK) != 0);

    LoginVisualProfile::ReceiptRecorder successful_recorder;
    ensure("the first eligible snapshot publishes a receipt", successful_recorder.observe(completion));
    const std::string receipt = readFile(receipt_path.path());
    ensure_equals("the receipt matches the generated document", receipt, LoginVisualProfile::receiptDocument(completion));
    ensure("a duplicate snapshot cannot publish again", !successful_recorder.observe(completion));
    ensure_equals("the duplicate leaves the receipt unchanged", readFile(receipt_path.path()), receipt);

    LoginVisualProfile::ReceiptRecorder replacement_recorder;
    ensure("a pre-existing receipt is never replaced", !replacement_recorder.observe(completion));
    ensure_equals("the pre-existing receipt remains unchanged", readFile(receipt_path.path()), receipt);
}

template<>
template<>
void oracle_login_visual_profile_test_object::test<5>()
{
    TemporaryReceiptPath existing_path;
    {
        std::ofstream existing(existing_path.path(), std::ios::binary);
        existing << "keep-existing-receipt";
    }
    LoginVisualProfile::ReceiptRecorder existing_recorder;
    ensure("an existing output file is refused", !existing_recorder.observe(eligibleSnapshot(existing_path.path())));
    ensure_equals("an existing output file is not overwritten", readFile(existing_path.path()), std::string("keep-existing-receipt"));

    LoginVisualProfile::ReceiptRecorder relative_recorder;
    ensure("a relative output path is refused", !relative_recorder.observe(eligibleSnapshot("oracle-login-visual-profile.json")));

    TemporaryDirectory final_symlink_directory;
    const std::string  final_symlink_path   = final_symlink_directory.path() + "/receipt.json";
    const std::string  final_symlink_target = final_symlink_directory.path() + "/redirected.json";
    ensure("a final symlink is created", ::symlink(final_symlink_target.c_str(), final_symlink_path.c_str()) == 0);
    LoginVisualProfile::ReceiptRecorder final_symlink_recorder;
    ensure("a final symlink is refused", !final_symlink_recorder.observe(eligibleSnapshot(final_symlink_path)));
    ensure("the final symlink target receives no receipt", ::access(final_symlink_target.c_str(), F_OK) != 0);

#ifdef LL_DARWIN
    TemporaryReceiptPath                canonical_tmp_path;
    const std::string::size_type        filename_start   = canonical_tmp_path.path().find_last_of('/') + 1;
    const std::string                   tmp_symlink_path = "/tmp/" + canonical_tmp_path.path().substr(filename_start);
    LoginVisualProfile::ReceiptRecorder tmp_symlink_recorder;
    ensure("the macOS /tmp symlink route is refused", !tmp_symlink_recorder.observe(eligibleSnapshot(tmp_symlink_path)));
    ensure("the canonical /private/tmp target receives no receipt", ::access(canonical_tmp_path.path().c_str(), F_OK) != 0);
#endif

    TemporaryDirectory directory;
    const std::string  real_parent   = directory.path() + "/real";
    const std::string  real_child    = real_parent + "/nested";
    const std::string  linked_parent = directory.path() + "/linked";
    ensure("the real output parent is created", ::mkdir(real_parent.c_str(), 0700) == 0);
    ensure("the nested real output parent is created", ::mkdir(real_child.c_str(), 0700) == 0);
    ensure("a symlinked output ancestor is created", ::symlink(real_parent.c_str(), linked_parent.c_str()) == 0);
    LoginVisualProfile::ReceiptRecorder ancestor_symlink_recorder;
    ensure("a symlinked output ancestor is refused",
           !ancestor_symlink_recorder.observe(eligibleSnapshot(linked_parent + "/nested/receipt.json")));
    ensure("the symlinked ancestor receives no receipt", ::access((real_child + "/receipt.json").c_str(), F_OK) != 0);
}

#if defined(LL_TEST_lloracleloginvisualprofile)
template<>
template<>
void oracle_login_visual_profile_test_object::test<6>()
{
    TemporaryDirectory directory;
    const std::string  original_parent    = directory.path() + "/original";
    const std::string  moved_parent       = directory.path() + "/moved";
    const std::string  replacement_parent = directory.path() + "/replacement";
    ensure("the output parent is created", ::mkdir(original_parent.c_str(), 0700) == 0);
    ensure("the replacement parent is created", ::mkdir(replacement_parent.c_str(), 0700) == 0);

    const LoginVisualProfile::Snapshot  snapshot         = eligibleSnapshot(original_parent + "/receipt.json");
    const std::string                   expected_receipt = LoginVisualProfile::receiptDocument(snapshot);
    OutputAncestorSwap                  ancestor_swap(original_parent, moved_parent, replacement_parent);
    ScopedPublicationTestHook           publication_hook(&OutputAncestorSwap::swap);
    LoginVisualProfile::ReceiptRecorder recorder;
    ensure("an ancestor replacement after traversal still publishes the receipt", recorder.observe(snapshot));
    ensure("the deterministic ancestor swap ran", ancestor_swap.succeeded());
    ensure_equals("the retained directory descriptor receives the receipt", readFile(moved_parent + "/receipt.json"), expected_receipt);
    ensure("the replacement symlink target receives no receipt", ::access((replacement_parent + "/receipt.json").c_str(), F_OK) != 0);
}

template<>
template<>
void oracle_login_visual_profile_test_object::test<7>()
{
    TemporaryReceiptPath                receipt_path;
    FinalLeafAbsenceProbe               final_leaf_probe(receipt_path.path());
    ScopedPublicationTestHook           publication_hook(&FinalLeafAbsenceProbe::inspect);
    LoginVisualProfile::ReceiptRecorder recorder;
    const LoginVisualProfile::Snapshot  snapshot = eligibleSnapshot(receipt_path.path());

    ensure("the unlinked staging descriptor is cloneable into the final leaf", recorder.observe(snapshot));
    ensure_equals("publication reaches both pre-clone inspection points", final_leaf_probe.invocationCount(), 2U);
    ensure("the final leaf stays absent until clone publication", final_leaf_probe.wasAlwaysAbsent());
    ensure_equals("the final clone has the complete receipt", readFile(receipt_path.path()), LoginVisualProfile::receiptDocument(snapshot));
}
#endif

} // namespace tut
