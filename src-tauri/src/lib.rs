use arboard::Clipboard;
use chrono::Local;
use image::ImageEncoder;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::io::Cursor;
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tauri::{
    menu::{MenuBuilder, MenuItemBuilder},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager,
};

const MAX_HISTORY: usize = 500;
const MAX_IMAGE_SIZE: usize = 10 * 1024 * 1024; // 10MB

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Settings {
    pub close_to_tray: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { close_to_tray: true }
    }
}

fn get_settings_path() -> std::path::PathBuf {
    let data_dir = dirs::data_local_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("ClipHist");
    std::fs::create_dir_all(&data_dir).ok();
    data_dir.join("settings.json")
}

fn load_settings() -> Settings {
    let path = get_settings_path();
    if let Ok(json) = std::fs::read_to_string(path) {
        if let Ok(s) = serde_json::from_str::<Settings>(&json) {
            return s;
        }
    }
    Settings::default()
}

fn save_settings(settings: &Settings) {
    if let Ok(json) = serde_json::to_string_pretty(settings) {
        let path = get_settings_path();
        let _ = std::fs::write(path, json);
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClipboardItem {
    pub id: usize,
    pub content: String,
    pub content_type: String, // "text" | "image" | "link" | "short" | "rich"
    pub timestamp: String,
    pub preview: String,
    pub char_count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_data: Option<String>, // base64 encoded image data
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_height: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub html_content: Option<String>, // original HTML rich text (Windows)
}

#[derive(Default)]
pub struct AppState {
    pub history: Arc<Mutex<Vec<ClipboardItem>>>,
    pub counter: Arc<Mutex<usize>>,
}

fn get_log_path() -> std::path::PathBuf {
    let data_dir = dirs::data_local_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("ClipHist");
    std::fs::create_dir_all(&data_dir).ok();
    data_dir.join("cliphist.log")
}

fn write_log(msg: &str) {
    use std::io::Write;
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(get_log_path())
    {
        let ts = chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f");
        let _ = writeln!(file, "[{}] {}", ts, msg);
        let _ = file.flush();
    }
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
    write_log("load_history: start");
    let path = get_storage_path();
    write_log(&format!("load_history: path={:?}", path));
    if let Ok(json) = std::fs::read_to_string(path) {
        if let Ok(items) = serde_json::from_str::<Vec<ClipboardItem>>(&json) {
            return items;
        }
    }
    Vec::new()
}

fn make_preview(content: &str) -> String {
    let trimmed = content.trim();
    if trimmed.char_indices().count() <= 80 {
        trimmed.to_string()
    } else {
        let preview: String = trimmed.chars().take(80).collect();
        format!("{}...", preview)
    }
}

fn get_content_type(content: &str) -> String {
    // Check if content contains any URL
    if content.contains("http://") || content.contains("https://") || content.contains("www.") {
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
fn copy_to_clipboard(
    state: tauri::State<'_, AppState>,
    id: usize,
) -> Result<(), String> {
    let history = state.history.lock();
    let item = history.iter().find(|i| i.id == id)
        .ok_or("Item not found")?;

    let mut clipboard = Clipboard::new().map_err(|e| e.to_string())?;

    // If item has image data, restore the image
    if let Some(ref img_data_b64) = item.image_data {
        if let Ok(img_bytes) =
            base64::Engine::decode(&base64::engine::general_purpose::STANDARD, img_data_b64)
        {
            let decoder = image::codecs::png::PngDecoder::new(Cursor::new(&img_bytes))
                .map_err(|e| e.to_string())?;
            let img: image::DynamicImage =
                image::DynamicImage::from_decoder(decoder).map_err(|e| e.to_string())?;
            let rgba = img.to_rgba8();
            let (w, h) = rgba.dimensions();
            let img_data = arboard::ImageData {
                width: w as usize,
                height: h as usize,
                bytes: rgba.into_raw().into(),
            };
            clipboard.set_image(img_data).map_err(|e| e.to_string())?;
            return Ok(());
        }
    }

    // If item has rich text HTML, restore it along with plain text
    if let Some(ref html) = item.html_content {
        let _ = clipboard.set().html(html, Some(&item.content));
        return Ok(());
    }

    // Otherwise restore text
    clipboard.set_text(&item.content).map_err(|e| e.to_string())?;
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

#[tauri::command]
fn get_settings() -> Settings {
    load_settings()
}

#[tauri::command]
fn save_settings_cmd(settings: Settings) {
    save_settings(&settings);
}

fn poll_clipboard(
    app_handle: AppHandle,
    state: Arc<Mutex<Vec<ClipboardItem>>>,
    counter: Arc<Mutex<usize>>,
) {
    let mut clipboard = match Clipboard::new() {
        Ok(c) => c,
        Err(_) => return,
    };

    // Track last content to avoid duplicates
    let mut last_text_hash: u64 = 0;
    let mut last_image_hash: u64 = 0;

    loop {
        thread::sleep(Duration::from_millis(500));

        // Try text first
        if let Ok(text) = clipboard.get_text() {
            let text = text.trim().to_string();
            if !text.is_empty() {
                // Also try to get HTML rich text (Windows)
                let html_content = clipboard.get().html().ok();
                let hash = simple_hash(&text);
                if hash != last_text_hash {
                    last_text_hash = hash;
                    last_image_hash = 0; // reset image hash
                    add_text_item(&app_handle, &state, &counter, &text, html_content);
                }
            }
        }

        // Try image
        if let Ok(img) = clipboard.get_image() {
            let img_hash = img_hash(&img);
            if img_hash != last_image_hash {
                last_image_hash = img_hash;
                last_text_hash = 0; // reset text hash
                add_image_item(&app_handle, &state, &counter, &img);
            }
        }
    }
}

fn simple_hash(s: &str) -> u64 {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    s.hash(&mut h);
    h.finish()
}

fn img_hash(img: &arboard::ImageData) -> u64 {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    (img.bytes.len(), img.width, img.height).hash(&mut h);
    h.finish()
}

fn add_text_item(
    app_handle: &AppHandle,
    state: &Arc<Mutex<Vec<ClipboardItem>>>,
    counter: &Arc<Mutex<usize>>,
    content: &str,
    html_content: Option<String>,
) {
    let id = {
        let mut c = counter.lock();
        *c += 1;
        *c
    };

    let content_type = if html_content.is_some() {
        "rich".to_string()
    } else {
        get_content_type(content)
    };

    let item = ClipboardItem {
        id,
        content: content.to_string(),
        content_type,
        timestamp: Local::now().format("%H:%M:%S").to_string(),
        preview: make_preview(content),
        char_count: content.len(),
        image_data: None,
        image_width: None,
        image_height: None,
        html_content,
    };

    {
        let mut history = state.lock();
        history.insert(0, item);
        if history.len() > MAX_HISTORY {
            history.truncate(MAX_HISTORY);
        }
        save_history(&history);
        let _ = app_handle.emit(
            "clipboard-changed",
            &history[..std::cmp::min(5, history.len())],
        );
    }
}

fn add_image_item(
    app_handle: &AppHandle,
    state: &Arc<Mutex<Vec<ClipboardItem>>>,
    counter: &Arc<Mutex<usize>>,
    img: &arboard::ImageData,
) {
    // Skip very large images
    if img.bytes.len() > MAX_IMAGE_SIZE {
        write_log(&format!("Image too large ({} bytes), skipping", img.bytes.len()));
        return;
    }

    // Convert to PNG for storage using image crate
    let rgba_img = image::RgbaImage::from_raw(
        img.width as u32,
        img.height as u32,
        img.bytes.to_vec(),
    );
    let rgba_img = match rgba_img {
        Some(img) => img,
        None => {
            write_log("Failed to create image from raw bytes");
            return;
        }
    };
    let mut png_bytes: Vec<u8> = Vec::new();
    let encoder = image::codecs::png::PngEncoder::new(&mut png_bytes);
    if let Err(e) = encoder.write_image(
        &rgba_img,
        rgba_img.width(),
        rgba_img.height(),
        image::ExtendedColorType::Rgba8,
    ) {
        write_log(&format!("Failed to encode image to PNG: {:?}", e));
        return;
    }

    let b64 = base64::Engine::encode(
        &base64::engine::general_purpose::STANDARD,
        &png_bytes,
    );

    let id = {
        let mut c = counter.lock();
        *c += 1;
        *c
    };

    let preview = format!("图片 {}x{}", img.width, img.height);

    let item = ClipboardItem {
        id,
        content: preview.clone(),
        content_type: "image".to_string(),
        timestamp: Local::now().format("%H:%M:%S").to_string(),
        preview,
        char_count: png_bytes.len(),
        image_data: Some(b64),
        image_width: Some(img.width as u32),
        image_height: Some(img.height as u32),
        html_content: None,
    };

    {
        let mut history = state.lock();
        history.insert(0, item);
        if history.len() > MAX_HISTORY {
            history.truncate(MAX_HISTORY);
        }
        save_history(&history);
        let _ = app_handle.emit(
            "clipboard-changed",
            &history[..std::cmp::min(5, history.len())],
        );
    }
}

fn setup_tray(app: &tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let quit = MenuItemBuilder::with_id("quit", "退出").build(app)?;
    let show = MenuItemBuilder::with_id("show", "显示窗口").build(app)?;
    let clear = MenuItemBuilder::with_id("clear", "清空历史").build(app)?;
    let settings = MenuItemBuilder::with_id("settings", "设置").build(app)?;

    let menu = MenuBuilder::new(app)
        .item(&show)
        .item(&settings)
        .item(&clear)
        .separator()
        .item(&quit)
        .build()?;

    // Get the default window icon set in tauri.conf.json
    let icon = app.default_window_icon().cloned()
        .ok_or("No default window icon set")?;

    let _tray = TrayIconBuilder::new()
        .icon(icon)
        .menu(&menu)
        .tooltip("ClipHist - 剪贴板历史")
        .on_menu_event(|app, event| match event.id().as_ref() {
            "quit" => {
                write_log("Quit menu item clicked, exiting");
                app.exit(0);
            }
            "show" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            "settings" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                    let _ = window.emit("open-settings", ());
                }
            }
            "clear" => {
                let state = app.state::<AppState>();
                let mut history = state.history.lock();
                history.clear();
                drop(history);
                save_history(&state.history.lock());
                let _ = app.emit("clipboard-changed", Vec::<ClipboardItem>::new());
                write_log("History cleared from tray menu");
            }
            _ => {}
        })
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
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    std::panic::set_hook(Box::new(|panic_info| {
        write_log(&format!("PANIC: {}", panic_info));
    }));

    write_log("ClipHist starting...");

    let history = load_history();
    write_log("load_history done");
    let counter = history.iter().map(|i| i.id).max().unwrap_or(0);
    write_log("counter computed");

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
            write_log("setup start");

            // Setup tray icon with menu
            write_log("building tray icon");
            if let Err(e) = setup_tray(app) {
                write_log(&format!("Failed to setup tray: {}", e));
            }

            // Intercept window close -> hide to tray instead of exiting
            let settings = load_settings();
            if settings.close_to_tray {
                if let Some(window) = app.get_webview_window("main") {
                    let app_handle = app.handle().clone();
                    window.on_window_event(move |event| {
                        if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                            api.prevent_close();
                            if let Some(win) = app_handle.get_webview_window("main") {
                                let _ = win.hide();
                            }
                        }
                    });
                }
            }

            // Start clipboard polling
            let app_handle = app.handle().clone();
            let state = app.state::<AppState>();
            let hist = state.history.clone();
            let cnt = state.counter.clone();
            write_log("spawning clipboard poll thread");
            thread::spawn(move || poll_clipboard(app_handle, hist, cnt));

            write_log("setup complete, app running");
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_history,
            search_history,
            copy_to_clipboard,
            delete_item,
            clear_history,
            get_item_count,
            get_settings,
            save_settings_cmd,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
