use crate::core::{consts, hotkey_parse, storage};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

const MAX_SETTINGS_FILE_SIZE: u64 = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
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
    storage::app_data_dir().join("settings.json")
}

pub fn load_settings() -> Settings {
    let path = get_settings_path();
    let loaded = match storage::load_json_with_backup::<Settings>(&path, MAX_SETTINGS_FILE_SIZE) {
        Ok(Some(settings)) => settings,
        Ok(None) => return Settings::default(),
        Err(error) => {
            crate::core::log::write_log(&format!(
                "Failed to load settings from {path:?}; using defaults: {error}"
            ));
            return Settings::default();
        }
    };
    let (settings, changed) = normalize_loaded_settings(loaded);
    if changed {
        crate::core::log::write_log("Normalized invalid or obsolete persisted settings");
        if let Err(error) = save_settings(&settings) {
            crate::core::log::write_log(&format!("Failed to persist normalized settings: {error}"));
        }
    }
    settings
}

pub fn save_settings(settings: &Settings) -> Result<(), String> {
    validate_settings(settings)?;
    let json = serde_json::to_string_pretty(settings)
        .map_err(|e| format!("Failed to serialize settings: {e}"))?;
    let path = get_settings_path();
    storage::atomic_write(&path, json.as_bytes())
}

pub fn validate_settings(settings: &Settings) -> Result<(), String> {
    if !settings.zoom_level.is_finite()
        || !(consts::MIN_ZOOM_LEVEL..=consts::MAX_ZOOM_LEVEL).contains(&settings.zoom_level)
    {
        return Err(format!("缩放比例超出范围: {}", settings.zoom_level));
    }
    if settings.retention_days > 365 {
        return Err(format!("保留天数超出范围: {}", settings.retention_days));
    }
    if !(320..=9999).contains(&settings.window_width) {
        return Err(format!("窗口宽度超出范围: {}", settings.window_width));
    }
    if !(400..=9999).contains(&settings.window_height) {
        return Err(format!("窗口高度超出范围: {}", settings.window_height));
    }
    if !hotkey_parse::validate_shortcut(&settings.hotkey) {
        return Err(format!("无效的快捷键格式: {}", settings.hotkey));
    }
    if !["", "Ctrl", "Shift", "Alt"].contains(&settings.double_tap_key.as_str()) {
        return Err(format!("无效的双击键: {}", settings.double_tap_key));
    }
    Ok(())
}

fn normalize_loaded_settings(mut settings: Settings) -> (Settings, bool) {
    if validate_settings(&settings).is_ok() {
        return (settings, false);
    }

    let defaults = Settings::default();
    if !settings.zoom_level.is_finite()
        || !(consts::MIN_ZOOM_LEVEL..=consts::MAX_ZOOM_LEVEL).contains(&settings.zoom_level)
    {
        settings.zoom_level = defaults.zoom_level;
    }
    if settings.retention_days > 365 {
        settings.retention_days = defaults.retention_days;
    }
    if !(320..=9999).contains(&settings.window_width) {
        settings.window_width = defaults.window_width;
    }
    if !(400..=9999).contains(&settings.window_height) {
        settings.window_height = defaults.window_height;
    }
    if !hotkey_parse::validate_shortcut(&settings.hotkey) {
        settings.hotkey = defaults.hotkey;
    }
    if !["", "Ctrl", "Shift", "Alt"].contains(&settings.double_tap_key.as_str()) {
        settings.double_tap_key = defaults.double_tap_key;
    }
    (settings, true)
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

    #[test]
    fn missing_fields_migrate_to_defaults() {
        let settings: Settings = serde_json::from_str(r#"{"close_to_tray":false}"#).unwrap();
        assert!(!settings.close_to_tray);
        assert_eq!(settings.hotkey, Settings::default().hotkey);
        assert_eq!(settings.window_width, Settings::default().window_width);
    }

    #[test]
    fn invalid_loaded_fields_are_normalized_individually() {
        let settings = Settings {
            zoom_level: f32::NAN,
            hotkey: "nope".to_string(),
            retention_days: 999,
            window_width: 1,
            ..Settings::default()
        };
        let (normalized, changed) = normalize_loaded_settings(settings);
        assert!(changed);
        assert!(validate_settings(&normalized).is_ok());
        assert_eq!(normalized, Settings::default());
    }
}
