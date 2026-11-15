//! Settings commands — 3 of the 11 `#[frb]` functions.

use crate::core::log;
use crate::core::settings_store::{self, Settings, SettingsPatch};
use crate::core::state;

/// In-memory settings (single source of truth). Synchronous.
#[flutter_rust_bridge::frb(sync)]
pub fn get_settings() -> Settings {
    state::st().settings.lock().clone()
}

/// Apply a partial settings patch transactionally. Validation happens against
/// a clone first, so an invalid multi-field patch cannot partially mutate the
/// in-memory settings. The file is saved before the shared snapshot is swapped
/// and before the double-tap side effect is applied.
pub fn update_settings(patch: SettingsPatch) -> Result<Settings, String> {
    let st = state::st();
    let mut current = st.settings.lock();
    let mut next = current.clone();
    let double_tap_change = patch.double_tap_key.clone();
    let game_mode_change = patch.game_mode;
    let auto_fullscreen_change = patch.auto_fullscreen_mode;

    if let Some(v) = patch.close_to_tray {
        next.close_to_tray = v;
    }
    if let Some(v) = patch.auto_start {
        next.auto_start = v;
    }
    if let Some(v) = patch.silent_start {
        next.silent_start = v;
    }
    if let Some(v) = patch.game_mode {
        next.game_mode = v;
    }
    if let Some(v) = patch.auto_fullscreen_mode {
        next.auto_fullscreen_mode = v;
    }
    if let Some(v) = patch.window_user_resized {
        next.window_user_resized = v;
    }

    if let Some(v) = patch.zoom_level {
        next.zoom_level = v;
    }
    if let Some(v) = patch.retention_days {
        next.retention_days = v;
    }
    if let Some(v) = patch.window_width {
        next.window_width = v;
    }
    if let Some(v) = patch.window_height {
        next.window_height = v;
    }
    if let Some(v) = patch.window_x {
        next.window_x = v;
    }
    if let Some(v) = patch.window_y {
        next.window_y = v;
    }
    if let Some(v) = patch.window_positioned {
        next.window_positioned = v;
    }
    if let Some(v) = patch.window_adaptive {
        next.window_adaptive = v;
    }
    if let Some(v) = patch.acrylic_enabled {
        next.acrylic_enabled = v;
    }
    if let Some(v) = patch.theme_mode {
        next.theme_mode = v;
    }
    if let Some(v) = patch.list_density {
        next.list_density = v;
    }

    if let Some(v) = patch.hotkey {
        next.hotkey = v;
    }
    if let Some(v) = patch.double_tap_key {
        next.double_tap_key = v;
    }

    settings_store::validate_settings(&next)?;
    settings_store::save_settings(&next).map_err(|e| format!("保存设置失败: {}", e))?;
    *current = next.clone();
    drop(current);

    if let Some(v) = double_tap_change {
        // A missing permission/helper is non-fatal: keep the preference and
        // report disconnected state, so the user can authorize/retry it.
        let start_result = crate::core::shortcut_engine::start_double_tap_listener(&v);
        if let Err(e) = &start_result {
            log::write_log(&format!("start_double_tap_listener failed: {}", e));
        }
    }
    if let Some(v) = game_mode_change {
        crate::core::shortcut_engine::set_manual_fullscreen_mode(v);
    }
    if auto_fullscreen_change == Some(false) {
        // Leave auto 全屏模式 right away instead of waiting for the next
        // detector tick. Turning it on is picked up by the detector loop.
        crate::core::shortcut_engine::set_auto_fullscreen_active(false);
    }

    Ok(next)
}

/// Whether 全屏模式 is currently on because a fullscreen app is in the
/// foreground (automatic detection, Windows only). Synchronous and cheap — an
/// atomic load — so the UI can poll it.
#[flutter_rust_bridge::frb(sync)]
pub fn auto_fullscreen_active() -> bool {
    crate::core::shortcut_engine::auto_fullscreen_active()
}

/// Is `hotkey` a syntactically valid global shortcut? Synchronous.
#[flutter_rust_bridge::frb(sync)]
pub fn validate_hotkey(hotkey: String) -> bool {
    crate::core::hotkey_parse::validate_shortcut(&hotkey)
}
