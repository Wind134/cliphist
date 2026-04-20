mod clipboard;
mod consts;
mod log;
mod settings;
mod shortcut;
mod state;
mod tray;

use clipboard::ClipboardItem;
use image::ImageEncoder;
use settings::Settings;
use state::AppState;
use tauri::{AppHandle, Emitter, Manager};

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
fn copy_to_clipboard(state: tauri::State<'_, AppState>, id: usize) -> Result<(), String> {
    let history = state.history.lock();
    clipboard::copy_item_to_clipboard(&history, id)
}

#[tauri::command]
fn delete_item(state: tauri::State<'_, AppState>, id: usize) {
    let mut history = state.history.lock();
    history.retain(|item| item.id != id);
    clipboard::save_history(&history);
}

#[tauri::command]
fn clear_history(state: tauri::State<'_, AppState>) {
    let mut history = state.history.lock();
    history.clear();
    clipboard::save_history(&history);
}

#[tauri::command]
fn get_item_count(state: tauri::State<'_, AppState>) -> usize {
    state.history.lock().len()
}

#[tauri::command]
fn get_settings() -> Settings {
    settings::load_settings()
}

#[tauri::command]
fn save_settings_cmd(settings: Settings) {
    settings::save_settings(&settings);
}

#[tauri::command]
fn update_settings(partial: serde_json::Value) -> Result<Settings, String> {
    let mut current = settings::load_settings();

    if let Some(v) = partial.get("close_to_tray").and_then(|v| v.as_bool()) {
        current.close_to_tray = v;
    }
    if let Some(v) = partial.get("zoom_level").and_then(|v| v.as_f64()) {
        let zoom = v as f32;
        if zoom >= consts::MIN_ZOOM_LEVEL && zoom <= consts::MAX_ZOOM_LEVEL {
            current.zoom_level = zoom;
        }
    }
    if let Some(v) = partial.get("hotkey").and_then(|v| v.as_str()) {
        if shortcut::validate_shortcut(v) {
            current.hotkey = v.to_string();
        } else {
            return Err(format!("无效的快捷键格式: {}", v));
        }
    }

    settings::save_settings(&current);
    Ok(current)
}

#[tauri::command]
fn validate_hotkey(hotkey: String) -> bool {
    shortcut::validate_shortcut(&hotkey)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    std::panic::set_hook(Box::new(|panic_info| {
        log::write_log(&format!("PANIC: {}", panic_info));
    }));

    log::write_log("ClipHist starting...");

    let history = clipboard::load_history();
    log::write_log("load_history done");
    let counter = history.iter().map(|i| i.id).max().unwrap_or(0);
    log::write_log("counter computed");

    let state = AppState {
        history: std::sync::Arc::new(parking_lot::Mutex::new(history)),
        counter: std::sync::Arc::new(parking_lot::Mutex::new(counter)),
    };

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .manage(state)
        .setup(|app| {
            log::write_log("setup start");

            log::write_log("building tray icon");
            if let Err(e) = tray::setup(app) {
                log::write_log(&format!("Failed to setup tray: {}", e));
            }

            let s = settings::load_settings();
            if let Err(e) = shortcut::register_global_shortcut(app, &s.hotkey) {
                log::write_log(&format!("Failed to register global shortcut: {}", e));
            }

            if s.close_to_tray {
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

            let app_handle = app.handle().clone();
            let state = app.state::<AppState>();
            let hist = state.history.clone();
            let cnt = state.counter.clone();
            log::write_log("spawning clipboard poll thread");

            std::thread::spawn(move || {
                poll_clipboard(app_handle, hist, cnt);
            });

            log::write_log("setup complete, app running");
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
            update_settings,
            validate_hotkey,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

fn poll_clipboard(
    app_handle: AppHandle,
    state: std::sync::Arc<parking_lot::Mutex<Vec<ClipboardItem>>>,
    counter: std::sync::Arc<parking_lot::Mutex<usize>>,
) {
    let mut clipboard = match arboard::Clipboard::new() {
        Ok(c) => c,
        Err(_) => return,
    };

    let mut last_text_hash: u64 = 0;
    let mut last_image_hash: u64 = 0;

    loop {
        std::thread::sleep(std::time::Duration::from_millis(500));

        if let Ok(text) = clipboard.get_text() {
            let text = text.trim().to_string();
            if !text.is_empty() {
                let html_content = clipboard.get().html().ok();
                let hash = simple_hash(&text);
                if hash != last_text_hash {
                    last_text_hash = hash;
                    last_image_hash = 0;

                    let id = {
                        let mut c = counter.lock();
                        *c += 1;
                        *c
                    };

                    let content_type = if html_content.is_some() {
                        "rich".to_string()
                    } else {
                        clipboard::get_content_type(&text)
                    };

                    let item = ClipboardItem {
                        id,
                        content: text.clone(),
                        content_type,
                        timestamp: chrono::Local::now().format("%H:%M:%S").to_string(),
                        preview: clipboard::make_preview(&text),
                        char_count: text.len(),
                        image_data: None,
                        image_width: None,
                        image_height: None,
                        html_content,
                    };

                    {
                        let mut history = state.lock();
                        history.insert(0, item);
                        if history.len() > consts::MAX_HISTORY {
                            history.truncate(consts::MAX_HISTORY);
                        }
                        clipboard::save_history(&history);
                        let _ = app_handle.emit(
                            "clipboard-changed",
                            &history[..std::cmp::min(5, history.len())],
                        );
                    }
                }
            }
        }

        if let Ok(img) = clipboard.get_image() {
            let img_hash_value = img_hash(&img);
            if img_hash_value != last_image_hash {
                last_image_hash = img_hash_value;
                last_text_hash = 0;

                if img.bytes.len() > consts::MAX_IMAGE_SIZE {
                    log::write_log(&format!(
                        "Image too large ({} bytes), skipping",
                        img.bytes.len()
                    ));
                    continue;
                }

                let rgba_img = image::RgbaImage::from_raw(
                    img.width as u32,
                    img.height as u32,
                    img.bytes.to_vec(),
                );
                let rgba_img = match rgba_img {
                    Some(img) => img,
                    None => {
                        log::write_log("Failed to create image from raw bytes");
                        continue;
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
                    log::write_log(&format!("Failed to encode image to PNG: {:?}", e));
                    continue;
                }

                let b64 =
                    base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &png_bytes);

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
                    timestamp: chrono::Local::now().format("%H:%M:%S").to_string(),
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
                    if history.len() > consts::MAX_HISTORY {
                        history.truncate(consts::MAX_HISTORY);
                    }
                    clipboard::save_history(&history);
                    let _ = app_handle.emit(
                        "clipboard-changed",
                        &history[..std::cmp::min(5, history.len())],
                    );
                }
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
    img.bytes.hash(&mut h);
    h.finish()
}
