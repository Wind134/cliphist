//! Settings commands — 3 of the 11 `#[frb]` functions.

use crate::core::consts;
use crate::core::hotkey_parse;
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

    if let Some(v) = patch.close_to_tray {
        next.close_to_tray = v;
    }
    if let Some(v) = patch.auto_start {
        next.auto_start = v;
    }
    if let Some(v) = patch.silent_start {
        next.silent_start = v;
    }
    if let Some(v) = patch.window_user_resized {
        next.window_user_resized = v;
    }

    if let Some(v) = patch.zoom_level {
        if !(consts::MIN_ZOOM_LEVEL..=consts::MAX_ZOOM_LEVEL).contains(&v) {
            return Err(format!("缩放比例超出范围: {}", v));
        }
        next.zoom_level = v;
    }
    if let Some(v) = patch.retention_days {
        if v > 365 {
            return Err(format!("保留天数超出范围: {}", v));
        }
        next.retention_days = v;
    }
    if let Some(v) = patch.window_width {
        if !(320..=9999).contains(&v) {
            return Err(format!("窗口宽度超出范围: {}", v));
        }
        next.window_width = v;
    }
    if let Some(v) = patch.window_height {
        if !(400..=9999).contains(&v) {
            return Err(format!("窗口高度超出范围: {}", v));
        }
        next.window_height = v;
    }

    if let Some(v) = patch.hotkey {
        if hotkey_parse::validate_shortcut(&v) {
            next.hotkey = v;
        } else {
            return Err(format!("无效的快捷键格式: {}", v));
        }
    }
    if let Some(v) = patch.double_tap_key {
        let valid_keys = ["", "Ctrl", "Shift", "Alt"];
        if !valid_keys.contains(&v.as_str()) {
            return Err(format!("无效的双击键: {}", v));
        }
        next.double_tap_key = v;
    }

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

    Ok(next)
}

/// Is `hotkey` a syntactically valid global shortcut? Synchronous.
#[flutter_rust_bridge::frb(sync)]
pub fn validate_hotkey(hotkey: String) -> bool {
    hotkey_parse::validate_shortcut(&hotkey)
}
