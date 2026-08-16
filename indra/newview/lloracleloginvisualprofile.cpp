/**
 * @file lloracleloginvisualprofile.cpp
 * @brief Developer-only runtime preflight for the OpenGL oracle login profile.
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

#include "lloracleloginvisualprofile.h"
#include "lloraclereceiptpublisher.h"

#include <boost/json.hpp>

#include <cmath>

namespace
{

constexpr char EXPECTED_LOGIN_PAGE[]            = "http://127.0.0.1:19472/login_ui/index.html";
constexpr char EXPECTED_SESSION_SETTINGS_FILE[] = "settings_firestorm.xml";
constexpr char EXPECTED_FONT_SETTINGS_FILE[]    = "fonts.xml";
constexpr char EXPECTED_LANGUAGE[]              = "en";
constexpr char EXPECTED_SKIN[]                  = "firestorm";
constexpr char EXPECTED_SKIN_THEME[]            = "grey";
constexpr char EXPECTED_XUI[]                   = "panel_fs_nui_login.xml";
constexpr char EXPECTED_LOGIN_LOCATION[]        = "last";

constexpr char RECEIPT_REASON[] = "This is a runtime configuration and layout preflight. It proves neither CEF response body or "
                                  "hash, CEF surface update, selected glyph fallback, a painted or presented frame, pixels, "
                                  "capture output or readiness, sRGB color space, lack of OS occlusion, nor machine admission.";

bool isExact(const double value, const double expected)
{
    return std::isfinite(value) && value == expected;
}

bool isValidRect(const LLOpenGLOracleLoginVisualProfile::Rect& rect)
{
    return rect.left < rect.right && rect.bottom < rect.top;
}

int width(const LLOpenGLOracleLoginVisualProfile::Rect& rect)
{
    return rect.right - rect.left;
}

int height(const LLOpenGLOracleLoginVisualProfile::Rect& rect)
{
    return rect.top - rect.bottom;
}

bool contains(const LLOpenGLOracleLoginVisualProfile::Rect& outer, const LLOpenGLOracleLoginVisualProfile::Rect& inner)
{
    return outer.left <= inner.left && outer.bottom <= inner.bottom && inner.right <= outer.right && inner.top <= outer.top;
}

bool hasSameExtent(const LLOpenGLOracleLoginVisualProfile::Rect& first, const LLOpenGLOracleLoginVisualProfile::Rect& second)
{
    return width(first) == width(second) && height(first) == height(second);
}

bool isRawDerivative(const LLOpenGLOracleLoginVisualProfile::Rect& ui_rect,
                     const LLOpenGLOracleLoginVisualProfile::Rect& raw_rect,
                     const double                                  scale_x,
                     const double                                  scale_y)
{
    return raw_rect.left == std::lround(ui_rect.left * scale_x) && raw_rect.right == std::lround(ui_rect.right * scale_x) &&
           raw_rect.bottom == std::lround(ui_rect.bottom * scale_y) && raw_rect.top == std::lround(ui_rect.top * scale_y);
}

bool isValidViewGeometry(const LLOpenGLOracleLoginVisualProfile::ViewGeometry& geometry,
                         const LLOpenGLOracleLoginVisualProfile::Rect&         window_scaled_ui,
                         const LLOpenGLOracleLoginVisualProfile::Rect&         window_raw_px,
                         const double                                          scale_x,
                         const double                                          scale_y)
{
    return isValidRect(geometry.local_ui) && isValidRect(geometry.viewer_screen_ui) && isValidRect(geometry.viewer_screen_raw_px_derived) &&
           hasSameExtent(geometry.local_ui, geometry.viewer_screen_ui) && contains(window_scaled_ui, geometry.viewer_screen_ui) &&
           isRawDerivative(geometry.viewer_screen_ui, geometry.viewer_screen_raw_px_derived, scale_x, scale_y) &&
           contains(window_raw_px, geometry.viewer_screen_raw_px_derived);
}

bool hasExpectedConfiguredLogin(const LLOpenGLOracleLoginVisualProfile::ConfiguredLogin& login)
{
    return login.login_page == EXPECTED_LOGIN_PAGE && login.force_login_url.empty() &&
           login.session_settings_file == EXPECTED_SESSION_SETTINGS_FILE;
}

bool hasExpectedProfileControls(const LLOpenGLOracleLoginVisualProfile::ProfileControls& controls)
{
    return controls.language == EXPECTED_LANGUAGE && controls.skin == EXPECTED_SKIN && controls.skin_theme == EXPECTED_SKIN_THEME &&
           !controls.use_legacy_login_panel && controls.font_settings_file == EXPECTED_FONT_SETTINGS_FILE &&
           isExact(controls.font_size_adjustment, 0.0) && controls.font_line_spacing_adjustment == 0 &&
           isExact(controls.font_screen_dpi, 96.0) && isExact(controls.ui_scale_factor, 1.0) && !controls.reset_ui_scale_on_first_run &&
           controls.render_hidpi && !controls.render_performance_test && !controls.first_login_this_install &&
           !controls.show_whitelist_reminder && controls.updater_show_release_notes == 0 && !controls.window_maximized &&
           controls.show_start_location && controls.login_location == EXPECTED_LOGIN_LOCATION &&
           controls.next_login_location == EXPECTED_LOGIN_LOCATION && !controls.force_show_grid &&
           !controls.opensim_always_force_show_grid && controls.remember_username && !controls.browser_proxy_enabled &&
           !controls.noninteractive_setting && !controls.headless_setting && controls.render_fsaa_samples == 0 &&
           controls.render_fsaa_type == 0 && !controls.render_ui_buffer;
}

bool hasExpectedEffectiveUI(const LLOpenGLOracleLoginVisualProfile::EffectiveUI& ui)
{
    const LLOpenGLOracleLoginVisualProfile::RequiredControls& controls = ui.required_controls;
    return ui.language == EXPECTED_LANGUAGE && ui.skin == EXPECTED_SKIN && ui.skin_theme == EXPECTED_SKIN_THEME &&
           ui.skin_language == EXPECTED_LANGUAGE && ui.selected_xui == EXPECTED_XUI && controls.login_html && controls.username_combo &&
           controls.password_edit && controls.start_location_combo && controls.server_combo && controls.mode_combo &&
           controls.start_location_panel && controls.grid_panel;
}

bool hasExpectedFontMetrics(const LLOpenGLOracleLoginVisualProfile::FontMetrics& metrics)
{
    return isExact(metrics.applied_horizontal_dpi, 192.0) && isExact(metrics.applied_vertical_dpi, 192.0) &&
           isExact(metrics.applied_scale_x, 2.0) && isExact(metrics.applied_scale_y, 2.0);
}

bool isVisibleStartLocationSelector(const LLOpenGLOracleLoginVisualProfile::SelectorState& selector)
{
    return selector.direct_visible && selector.visible_chain && isExact(selector.visible_amount, 1.0);
}

bool isHiddenGridSelector(const LLOpenGLOracleLoginVisualProfile::SelectorState& selector)
{
    return !selector.direct_visible && !selector.visible_chain && isExact(selector.visible_amount, 0.0);
}

bool hasExpectedLoginState(const LLOpenGLOracleLoginVisualProfile::LoginState& state)
{
    return state.credential_store_count == 0 && state.username_combo_item_count == 0 && state.username_entry_empty &&
           state.password_entry_empty && !state.favorites_present && state.selected_location == EXPECTED_LOGIN_LOCATION &&
           isVisibleStartLocationSelector(state.start_location_selector) && isHiddenGridSelector(state.grid_selector);
}

bool hasExpectedUIState(const LLOpenGLOracleLoginVisualProfile::UIState& state)
{
    return !state.noninteractive_runtime && !state.headless_runtime && state.modal_dialog_count == 0 &&
           state.visible_notification_count == 0 && !state.top_control_present && state.window_visible && !state.window_minimized &&
           !state.window_maximized && !state.window_fullscreen;
}

bool hasExpectedDisplay(const LLOpenGLOracleLoginVisualProfile::DisplayState& display)
{
    return isExact(display.backing_scale, 2.0) && isExact(display.ui_scale_factor, 1.0) && isExact(display.display_scale_x, 2.0) &&
           isExact(display.display_scale_y, 2.0) && isExact(display.pixel_aspect_ratio, 1.0) && isValidRect(display.window_raw_px) &&
           width(display.window_raw_px) == 1920 && height(display.window_raw_px) == 1080 && isValidRect(display.window_scaled_ui) &&
           width(display.window_scaled_ui) == 960 && height(display.window_scaled_ui) == 540 &&
           isRawDerivative(display.window_scaled_ui, display.window_raw_px, display.display_scale_x, display.display_scale_y) &&
           isValidViewGeometry(display.login_holder,
                               display.window_scaled_ui,
                               display.window_raw_px,
                               display.display_scale_x,
                               display.display_scale_y) &&
           isValidViewGeometry(display.login_panel,
                               display.window_scaled_ui,
                               display.window_raw_px,
                               display.display_scale_x,
                               display.display_scale_y) &&
           contains(display.login_holder.viewer_screen_ui, display.login_panel.viewer_screen_ui) &&
           contains(display.login_holder.viewer_screen_raw_px_derived, display.login_panel.viewer_screen_raw_px_derived);
}

boost::json::object toJson(const LLOpenGLOracleLoginVisualProfile::Rect& rect)
{
    return {
        { "left", rect.left },
        { "bottom", rect.bottom },
        { "right", rect.right },
        { "top", rect.top },
    };
}

boost::json::object toJson(const LLOpenGLOracleLoginVisualProfile::ViewGeometry& geometry)
{
    return {
        { "local_ui", toJson(geometry.local_ui) },
        { "viewer_screen_ui", toJson(geometry.viewer_screen_ui) },
        { "viewer_screen_raw_px_derived", toJson(geometry.viewer_screen_raw_px_derived) },
    };
}

boost::json::object toJson(const LLOpenGLOracleLoginVisualProfile::RequiredControls& controls)
{
    return {
        { "login_html", controls.login_html },
        { "username_combo", controls.username_combo },
        { "password_edit", controls.password_edit },
        { "start_location_combo", controls.start_location_combo },
        { "server_combo", controls.server_combo },
        { "mode_combo", controls.mode_combo },
        { "start_location_panel", controls.start_location_panel },
        { "grid_panel", controls.grid_panel },
    };
}

boost::json::object toJson(const LLOpenGLOracleLoginVisualProfile::SelectorState& selector)
{
    return {
        { "direct_visible", selector.direct_visible },
        { "visible_chain", selector.visible_chain },
        { "visible_amount", selector.visible_amount },
    };
}

boost::json::object toJson(const LLOpenGLOracleLoginVisualProfile::ConfiguredLogin& login)
{
    return {
        { "login_page", login.login_page },
        { "force_login_url_empty", login.force_login_url.empty() },
        { "session_settings_file", login.session_settings_file },
    };
}

boost::json::object toJson(const LLOpenGLOracleLoginVisualProfile::ProfileControls& controls)
{
    return {
        { "language", controls.language },
        { "skin", controls.skin },
        { "skin_theme", controls.skin_theme },
        { "use_legacy_login_panel", controls.use_legacy_login_panel },
        { "font_settings_file", controls.font_settings_file },
        { "font_size_adjustment", controls.font_size_adjustment },
        { "font_line_spacing_adjustment", controls.font_line_spacing_adjustment },
        { "font_screen_dpi", controls.font_screen_dpi },
        { "ui_scale_factor", controls.ui_scale_factor },
        { "reset_ui_scale_on_first_run", controls.reset_ui_scale_on_first_run },
        { "render_hidpi", controls.render_hidpi },
        { "render_performance_test", controls.render_performance_test },
        { "first_login_this_install", controls.first_login_this_install },
        { "show_whitelist_reminder", controls.show_whitelist_reminder },
        { "updater_show_release_notes", controls.updater_show_release_notes },
        { "window_maximized", controls.window_maximized },
        { "show_start_location", controls.show_start_location },
        { "login_location", controls.login_location },
        { "next_login_location", controls.next_login_location },
        { "force_show_grid", controls.force_show_grid },
        { "opensim_always_force_show_grid", controls.opensim_always_force_show_grid },
        { "remember_username", controls.remember_username },
        { "browser_proxy_enabled", controls.browser_proxy_enabled },
        { "noninteractive_setting", controls.noninteractive_setting },
        { "headless_setting", controls.headless_setting },
        { "render_fsaa_samples", controls.render_fsaa_samples },
        { "render_fsaa_type", controls.render_fsaa_type },
        { "render_ui_buffer", controls.render_ui_buffer },
    };
}

boost::json::object toJson(const LLOpenGLOracleLoginVisualProfile::EffectiveUI& ui)
{
    return {
        { "language", ui.language },         { "skin", ui.skin },
        { "skin_theme", ui.skin_theme },     { "skin_language", ui.skin_language },
        { "selected_xui", ui.selected_xui }, { "required_controls_present", toJson(ui.required_controls) },
    };
}

boost::json::object toJson(const LLOpenGLOracleLoginVisualProfile::FontMetrics&     metrics,
                           const LLOpenGLOracleLoginVisualProfile::ProfileControls& controls)
{
    return {
        { "configured_file", controls.font_settings_file },
        { "configured_size_adjustment", controls.font_size_adjustment },
        { "configured_line_spacing_adjustment", controls.font_line_spacing_adjustment },
        { "configured_screen_dpi", controls.font_screen_dpi },
        { "applied_horizontal_dpi", metrics.applied_horizontal_dpi },
        { "applied_vertical_dpi", metrics.applied_vertical_dpi },
        { "applied_scale_x", metrics.applied_scale_x },
        { "applied_scale_y", metrics.applied_scale_y },
    };
}

boost::json::object toJson(const LLOpenGLOracleLoginVisualProfile::LoginState& state)
{
    return {
        { "credential_store_count", state.credential_store_count },
        { "username_combo_item_count", state.username_combo_item_count },
        { "username_entry_empty", state.username_entry_empty },
        { "password_entry_empty", state.password_entry_empty },
        { "favorites_present", state.favorites_present },
        { "selected_location", state.selected_location },
        { "selectors",
          {
              { "start_location", toJson(state.start_location_selector) },
              { "grid", toJson(state.grid_selector) },
          } },
    };
}

boost::json::object toJson(const LLOpenGLOracleLoginVisualProfile::UIState& state)
{
    return {
        { "noninteractive_runtime", state.noninteractive_runtime },
        { "headless_runtime", state.headless_runtime },
        { "modal_dialog_count", state.modal_dialog_count },
        { "visible_notification_count", state.visible_notification_count },
        { "top_control_present", state.top_control_present },
        { "window_visible", state.window_visible },
        { "window_minimized", state.window_minimized },
        { "window_maximized", state.window_maximized },
        { "window_fullscreen", state.window_fullscreen },
    };
}

boost::json::object toJson(const LLOpenGLOracleLoginVisualProfile::DisplayState& display)
{
    return {
        { "backing_scale", display.backing_scale },
        { "ui_scale_factor", display.ui_scale_factor },
        { "display_scale",
          {
              { "x", display.display_scale_x },
              { "y", display.display_scale_y },
          } },
        { "pixel_aspect_ratio", display.pixel_aspect_ratio },
        { "window_raw_px", toJson(display.window_raw_px) },
        { "window_scaled_ui", toJson(display.window_scaled_ui) },
        { "login_holder", toJson(display.login_holder) },
        { "login_panel", toJson(display.login_panel) },
    };
}

} // anonymous namespace

namespace LLOpenGLOracleLoginVisualProfile
{

bool isEligibleSnapshot(const Snapshot& snapshot)
{
    return hasExpectedConfiguredLogin(snapshot.configured_login) && hasExpectedProfileControls(snapshot.profile_controls) &&
           hasExpectedEffectiveUI(snapshot.effective_ui) && hasExpectedFontMetrics(snapshot.font_metrics) &&
           hasExpectedLoginState(snapshot.login_state) && hasExpectedUIState(snapshot.ui_state) && hasExpectedDisplay(snapshot.display);
}

std::string receiptDocument(const Snapshot& snapshot)
{
    if (!isEligibleSnapshot(snapshot))
    {
        return {};
    }

    boost::json::object document = {
        { "schema", 1 },
        { "kind", "firestorm-opengl-oracle-login-visual-profile" },
        { "admissible", false },
        { "status", "inadmissible" },
        { "reason", RECEIPT_REASON },
        { "developer_capture_build", true },
        { "configured_login", toJson(snapshot.configured_login) },
        { "profile_controls", toJson(snapshot.profile_controls) },
        { "effective_ui", toJson(snapshot.effective_ui) },
        { "font", toJson(snapshot.font_metrics, snapshot.profile_controls) },
        { "login_state", toJson(snapshot.login_state) },
        { "ui_state", toJson(snapshot.ui_state) },
        { "display", toJson(snapshot.display) },
    };
    return boost::json::serialize(document);
}

bool ReceiptRecorder::observe(const Snapshot& snapshot)
{
    {
        std::lock_guard<std::mutex> lock(mMutex);
        if (mSnapshotConsumed)
        {
            return false;
        }
        mSnapshotConsumed = true;
    }

    const std::string document = receiptDocument(snapshot);
    if (document.empty())
    {
        LL_WARNS("OpenGLOracle") << "Login visual-profile preflight snapshot was ineligible; no receipt was published." << LL_ENDL;
        return false;
    }

    if (!LLOpenGLOracleReceiptPublisher::publishNoReplace(snapshot.receipt_path, document))
    {
        LL_WARNS("OpenGLOracle") << "Login visual-profile preflight receipt publication was refused." << LL_ENDL;
        return false;
    }

    return true;
}

bool ReceiptRecorder::hasConsumedSnapshot() const
{
    std::lock_guard<std::mutex> lock(mMutex);
    return mSnapshotConsumed;
}

bool observeVisualProfile(const Snapshot& snapshot)
{
    static ReceiptRecorder recorder;
    return recorder.observe(snapshot);
}

} // namespace LLOpenGLOracleLoginVisualProfile
