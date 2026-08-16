/**
 * @file lloracleloginvisualprofile.h
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

#ifndef LL_LLORACLELOGINVISUALPROFILE_H
#define LL_LLORACLELOGINVISUALPROFILE_H

#include <mutex>
#include <string>

namespace LLOpenGLOracleLoginVisualProfile
{

// Viewer-root coordinates use the lower-left convention. The helper accepts
// plain values so its eligibility contract stays testable without UI objects.
struct Rect
{
    int left   = 0;
    int bottom = 0;
    int right  = 0;
    int top    = 0;
};

struct ConfiguredLogin
{
    std::string login_page;
    std::string force_login_url;
    std::string session_settings_file;
};

// These are the remaining typed controls from login_ui.conditions.settings.
// LoginPage, ForceLoginURL, and SessionSettingsFile live in ConfiguredLogin.
struct ProfileControls
{
    std::string language;
    std::string skin;
    std::string skin_theme;
    bool        use_legacy_login_panel = false;
    std::string font_settings_file;
    double      font_size_adjustment         = 0.0;
    int         font_line_spacing_adjustment = 0;
    double      font_screen_dpi              = 0.0;
    double      ui_scale_factor              = 0.0;
    bool        reset_ui_scale_on_first_run  = false;
    bool        render_hidpi                 = false;
    bool        render_performance_test      = false;
    bool        first_login_this_install     = false;
    bool        show_whitelist_reminder      = false;
    int         updater_show_release_notes   = 0;
    bool        window_maximized             = false;
    bool        show_start_location          = false;
    std::string login_location;
    std::string next_login_location;
    bool        force_show_grid                = false;
    bool        opensim_always_force_show_grid = false;
    bool        remember_username              = false;
    bool        browser_proxy_enabled          = false;
    bool        noninteractive_setting         = false;
    bool        headless_setting               = false;
    int         render_fsaa_samples            = 0;
    int         render_fsaa_type               = 0;
    bool        render_ui_buffer               = false;
};

struct RequiredControls
{
    bool login_html           = false;
    bool username_combo       = false;
    bool password_edit        = false;
    bool start_location_combo = false;
    bool server_combo         = false;
    bool mode_combo           = false;
    bool start_location_panel = false;
    bool grid_panel           = false;
};

struct EffectiveUI
{
    std::string      language;
    std::string      skin;
    std::string      skin_theme;
    std::string      skin_language;
    std::string      selected_xui;
    RequiredControls required_controls;
};

struct FontMetrics
{
    double applied_horizontal_dpi = 0.0;
    double applied_vertical_dpi   = 0.0;
    double applied_scale_x        = 0.0;
    double applied_scale_y        = 0.0;
};

struct SelectorState
{
    bool   direct_visible = false;
    bool   visible_chain  = false;
    double visible_amount = 0.0;
};

struct LoginState
{
    int           credential_store_count    = 0;
    int           username_combo_item_count = 0;
    bool          username_entry_empty      = false;
    bool          password_entry_empty      = false;
    bool          favorites_present         = false;
    std::string   selected_location;
    SelectorState start_location_selector;
    SelectorState grid_selector;
};

struct UIState
{
    bool noninteractive_runtime     = false;
    bool headless_runtime           = false;
    int  modal_dialog_count         = 0;
    int  visible_notification_count = 0;
    bool top_control_present        = false;
    bool window_visible             = false;
    bool window_minimized           = false;
    bool window_maximized           = false;
    bool window_fullscreen          = false;
};

struct ViewGeometry
{
    Rect local_ui;
    Rect viewer_screen_ui;
    Rect viewer_screen_raw_px_derived;
};

struct DisplayState
{
    double       backing_scale      = 0.0;
    double       ui_scale_factor    = 0.0;
    double       display_scale_x    = 0.0;
    double       display_scale_y    = 0.0;
    double       pixel_aspect_ratio = 0.0;
    Rect         window_raw_px;
    Rect         window_scaled_ui;
    ViewGeometry login_holder;
    ViewGeometry login_panel;
};

struct Snapshot
{
    ConfiguredLogin configured_login;
    ProfileControls profile_controls;
    EffectiveUI     effective_ui;
    FontMetrics     font_metrics;
    LoginState      login_state;
    UIState         ui_state;
    DisplayState    display;
    std::string     receipt_path;
};

// Purely validates the configuration and observable runtime layout state. It
// cannot establish CEF response provenance, a rendered frame, capture pixels,
// output colour space, or whether another process occludes the native window.
bool isEligibleSnapshot(const Snapshot& snapshot);

// Returns a receipt only for an eligible snapshot. It intentionally omits the
// output path and all user identifiers, credentials, favorites, and URLs.
std::string receiptDocument(const Snapshot& snapshot);

class ReceiptRecorder
{
public:
    // The first settled snapshot is consumed even when it is ineligible or
    // publication fails. This prevents a later state from recovering a receipt.
    bool observe(const Snapshot& snapshot);
    bool hasConsumedSnapshot() const;

private:
    mutable std::mutex mMutex;
    bool               mSnapshotConsumed = false;
};

// The production entry point uses one mutex-protected recorder for the whole
// process. Call only after a live login panel has reached a settled idle state.
bool observeVisualProfile(const Snapshot& snapshot);

} // namespace LLOpenGLOracleLoginVisualProfile

#endif // LL_LLORACLELOGINVISUALPROFILE_H
