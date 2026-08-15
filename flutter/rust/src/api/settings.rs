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

/// Apply a partial settings patch. Type-safe field extraction via
/// [`SettingsPatch`]; bounded numeric fields are clamped; side-effecting
/// fields (autostart, hotkey registration, double-tap listener) are validated
/// here but their OS-level effects are wired in M5/M7/M8 respectively — M2
/// persists the value and logs the deferral.
pub fn update_settings(patch: SettingsPatch) -> Result<Settings, String> {
    let st = state::st();
    let mut current = st.settings.lock();

    // Plain fields: apply directly, no validation needed.
    if let Some(v) = patch.close_to_tray {
        current.close_to_tray = v;
    }
    if let Some(v) = patch.auto_start {
        // M5: wire launch_at_startup (Dart). M2 only persists the flag.
        log::write_log(&format!(
            "auto_start -> {} (autostart side-effect deferred to M5)",
            v
        ));
        current.auto_start = v;
    }
    if let Some(v) = patch.silent_start {
        current.silent_start = v;
    }
    if let Some(v) = patch.window_user_resized {
        current.window_user_resized = v;
    }

    // Bounded numeric fields: clamp to their allowed ranges.
    if let Some(v) = patch.zoom_level {
        if (consts::MIN_ZOOM_LEVEL..=consts::MAX_ZOOM_LEVEL).contains(&v) {
            current.zoom_level = v;
        }
    }
    if let Some(v) = patch.retention_days {
        if v <= 365 {
            current.retention_days = v;
        }
    }
    if let Some(v) = patch.window_width {
        if (320..=9999).contains(&v) {
            current.window_width = v;
        }
    }
    if let Some(v) = patch.window_height {
        if (400..=9999).contains(&v) {
            current.window_height = v;
        }
    }

    // Side-effecting fields: validate format, persist; OS effect deferred.
    if let Some(v) = patch.hotkey {
        if hotkey_parse::validate_shortcut(&v) {
            // M7: register via global-hotkey. M2 only validates + persists.
            log::write_log(&format!("hotkey -> {} (registration deferred to M7)", v));
            current.hotkey = v;
        } else {
            return Err(format!("无效的快捷键格式: {}", v));
        }
    }
    if let Some(v) = patch.double_tap_key {
        let valid_keys = ["", "Ctrl", "Shift", "Alt"];
        if !valid_keys.contains(&v.as_str()) {
            return Err(format!("无效的双击键: {}", v));
        }
        // M7/M8: start/stop the real listener. M2 only validates + persists.
        log::write_log(&format!(
            "double_tap_key -> {} (listener deferred to M7/M8)",
            v
        ));
        current.double_tap_key = v;
    }

    let result = current.clone();
    settings_store::save_settings(&current).map_err(|e| format!("保存设置失败: {}", e))?;
    Ok(result)
}

/// Is `hotkey` a syntactically valid global shortcut? Synchronous.
#[flutter_rust_bridge::frb(sync)]
pub fn validate_hotkey(hotkey: String) -> bool {
    hotkey_parse::validate_shortcut(&hotkey)
}
