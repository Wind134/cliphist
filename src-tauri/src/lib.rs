use arboard::Clipboard;
use chrono::Local;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tauri::{
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Emitter, Manager,
};

const MAX_HISTORY: usize = 500;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClipboardItem {
    pub id: usize,
    pub content: String,
    pub content_type: String,
    pub timestamp: String,
    pub preview: String,
    pub char_count: usize,
}

#[derive(Default)]
pub struct AppState {
    pub history: Arc<Mutex<Vec<ClipboardItem>>>,
    pub counter: Arc<Mutex<usize>>,
}

fn get_storage_path() -> std::path::PathBuf {
    let data_dir = dirs::data_local_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("ClipHist");
    std::fs::create_dir_all(&data_dir).ok();
    data_dir.join("history.json")
}

fn save_history(items: &[ClipboardItem]) {
    if let Ok(json) = serde_json::to_string_pretty(items) {
        let path = get_storage_path();
        let _ = std::fs::write(path, json);
    }
}

fn load_history() -> Vec<ClipboardItem> {
    let path = get_storage_path();
    if let Ok(json) = std::fs::read_to_string(path) {
        if let Ok(items) = serde_json::from_str::<Vec<ClipboardItem>>(&json) {
            return items;
        }
    }
    Vec::new()
}

fn make_preview(content: &str) -> String {
    let trimmed = content.trim();
    if trimmed.len() <= 80 {
        trimmed.to_string()
    } else {
        format!("{}...", &trimmed[..80])
    }
}

fn get_content_type(content: &str) -> String {
    if content.starts_with("http://") || content.starts_with("https://") {
        "link".to_string()
    } else if content.len() > 100 && content.contains('\n') {
        "text".to_string()
    } else if content.len() > 50 {
        "text".to_string()
    } else {
        "short".to_string()
    }
}

#[tauri::command]
fn get_history(state: tauri::State<'_, AppState>) -> Vec<ClipboardItem> {
    state.history.lock().clone()
}

#[tauri::command]
fn search_history(state: tauri::State<'_, AppState>, query: String) -> Vec<ClipboardItem> {
    let history = state.history.lock();
    let query_lower = query.to_lowercase();
    history
        .iter()
        .filter(|item| item.content.to_lowercase().contains(&query_lower))
        .cloned()
        .collect()
}

#[tauri::command]
fn copy_to_clipboard(content: String) -> Result<(), String> {
    let mut clipboard = Clipboard::new().map_err(|e| e.to_string())?;
    clipboard.set_text(&content).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn delete_item(state: tauri::State<'_, AppState>, id: usize) {
    let mut history = state.history.lock();
    history.retain(|item| item.id != id);
    save_history(&history);
}

#[tauri::command]
fn clear_history(state: tauri::State<'_, AppState>) {
    let mut history = state.history.lock();
    history.clear();
    save_history(&history);
}

#[tauri::command]
fn get_item_count(state: tauri::State<'_, AppState>) -> usize {
    state.history.lock().len()
}

fn poll_clipboard(app_handle: tauri::AppHandle, state: Arc<Mutex<Vec<ClipboardItem>>>, counter: Arc<Mutex<usize>>) {
    let mut clipboard = match Clipboard::new() {
        Ok(c) => c,
        Err(_) => return,
    };
    let mut last_content = String::new();

    loop {
        thread::sleep(Duration::from_millis(500));

        if let Ok(content) = clipboard.get_text() {
            let content = content.trim().to_string();
            if content.is_empty() || content == last_content {
                continue;
            }
            last_content = content.clone();

            let mut history = state.lock();
            let id = {
                let mut c = counter.lock();
                *c += 1;
                *c
            };

            let item = ClipboardItem {
                id,
                content: content.clone(),
                content_type: get_content_type(&content),
                timestamp: Local::now().format("%H:%M:%S").to_string(),
                preview: make_preview(&content),
                char_count: content.len(),
            };

            history.insert(0, item);

            if history.len() > MAX_HISTORY {
                history.truncate(MAX_HISTORY);
            }

            save_history(&history);

            let _ = app_handle.emit("clipboard-changed", &history[..std::cmp::min(5, history.len())]);
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    env_logger::init();

    let history = load_history();
    let counter = history.iter().map(|i| i.id).max().unwrap_or(0);

    let state = AppState {
        history: Arc::new(Mutex::new(history)),
        counter: Arc::new(Mutex::new(counter)),
    };

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .manage(state)
        .setup(|app| {
            let app_handle = app.handle().clone();
            let state = app.state::<AppState>();
            let hist = state.history.clone();
            let cnt = state.counter.clone();

            thread::spawn(move || poll_clipboard(app_handle, hist, cnt));

            let _tray = TrayIconBuilder::new()
                .tooltip("ClipHist - 剪贴板历史")
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        let app = tray.app_handle();
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                })
                .build(app)?;

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_history,
            search_history,
            copy_to_clipboard,
            delete_item,
            clear_history,
            get_item_count
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
