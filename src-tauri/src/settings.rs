use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Settings {
    pub close_to_tray: bool,
    pub zoom_level: f32,
    pub hotkey: String,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            close_to_tray: true,
            zoom_level: 1.0,
            hotkey: "Ctrl+Shift+V".to_string(),
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
    if let Ok(json) = std::fs::read_to_string(path) {
        if let Ok(s) = serde_json::from_str::<Settings>(&json) {
            return s;
        }
    }
    Settings::default()
}

pub fn save_settings(settings: &Settings) {
    if let Ok(json) = serde_json::to_string_pretty(settings) {
        let path = get_settings_path();
        let _ = std::fs::write(path, json);
    }
}
