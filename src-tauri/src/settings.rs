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
            crate::log::write_log(&format!("Settings loaded: retention_days={}", s.retention_days));
            return s;
        }
        crate::log::write_log(&format!("Failed to parse settings from {:?}", path));
    } else {
        crate::log::write_log(&format!("No settings file at {:?}, using defaults", path));
    }
    Settings::default()
}

pub fn save_settings(settings: &Settings) -> Result<(), String> {
    let json = serde_json::to_string_pretty(settings)
        .map_err(|e| format!("Failed to serialize settings: {}", e))?;
    let path = get_settings_path();
    std::fs::write(&path, json)
        .map_err(|e| format!("Failed to save settings to {:?}: {}", path, e))?;
    Ok(())
}
