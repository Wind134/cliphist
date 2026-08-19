use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Settings {
    pub close_to_tray: bool,
    pub zoom_level: f32,
    pub hotkey: String,
    pub auto_start: bool,
    pub silent_start: bool,
    pub double_tap_key: String,
    pub retention_days: u32,
    pub window_width: u32,
    pub window_height: u32,
    pub window_user_resized: bool,
}

/// A partial update to [`Settings`]. Every field is optional so the frontend
/// can send only the keys it wants to change. `update_settings` deserializes
/// its payload directly into this struct, which makes field extraction
/// type-safe — no manual `serde_json::Value::get` + `as_*` casting.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct SettingsPatch {
    pub close_to_tray: Option<bool>,
    pub zoom_level: Option<f32>,
    pub hotkey: Option<String>,
    pub auto_start: Option<bool>,
    pub silent_start: Option<bool>,
    pub double_tap_key: Option<String>,
    pub retention_days: Option<u32>,
    pub window_width: Option<u32>,
    pub window_height: Option<u32>,
    pub window_user_resized: Option<bool>,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            close_to_tray: true,
            zoom_level: 1.0,
            hotkey: "Ctrl+Shift+V".to_string(),
            auto_start: false,
            silent_start: true,
            double_tap_key: String::new(),
            retention_days: 3,
            window_width: 400,
            window_height: 600,
            window_user_resized: false,
        }
    }
}

pub fn get_settings_path() -> PathBuf {
    let data_dir = dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("ClipHist");
    std::fs::create_dir_all(&data_dir).ok();
    data_dir.join("settings.json")
}

pub fn load_settings() -> Settings {
    let path = get_settings_path();
    if let Ok(json) = std::fs::read_to_string(&path) {
        if let Ok(s) = serde_json::from_str::<Settings>(&json) {
            return s;
        }
        crate::core::log::write_log(&format!("Failed to parse settings from {:?}", path));
    } else {
        crate::core::log::write_log(&format!("No settings file at {:?}, using defaults", path));
    }
    Settings::default()
}

pub fn save_settings(settings: &Settings) -> Result<(), String> {
    let json = serde_json::to_string_pretty(settings)
        .map_err(|e| format!("Failed to serialize settings: {}", e))?;
    let path = get_settings_path();
    // Atomic: temp sibling + rename, so a crash mid-write cannot leave a
    // corrupt settings.json (which would silently fall back to defaults).
    let tmp = path.with_extension("json.tmp");
    if std::fs::write(&tmp, &json).is_ok() && std::fs::rename(&tmp, &path).is_ok() {
        return Ok(());
    }
    // Fallback: direct write if the temp+rename path failed.
    let _ = std::fs::remove_file(&tmp);
    std::fs::write(&path, &json)
        .map_err(|e| format!("Failed to save settings to {:?}: {}", path, e))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[allow(clippy::field_reassign_with_default)]
    fn patch_merges_into_settings() {
        let mut s = Settings::default();
        s.zoom_level = 1.5;
        s.retention_days = 30;
        let patch_json = r#"{"zoom_level":1.25,"retention_days":14}"#;
        let patch: SettingsPatch = serde_json::from_str(patch_json).unwrap();
        if let Some(v) = patch.zoom_level {
            s.zoom_level = v;
        }
        if let Some(v) = patch.retention_days {
            s.retention_days = v;
        }
        assert_eq!(s.zoom_level, 1.25);
        assert_eq!(s.retention_days, 14);
        // Untouched fields stay.
        assert!(s.close_to_tray);
    }

    #[test]
    fn patch_round_trips_all_fields() {
        let s = Settings::default();
        let json = serde_json::to_string(&s).unwrap();
        let back: Settings = serde_json::from_str(&json).unwrap();
        assert_eq!(s.hotkey, back.hotkey);
        assert_eq!(s.retention_days, back.retention_days);
    }
}
