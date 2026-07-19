pub(crate) mod log;
mod clipboard;
mod consts;
#[cfg(target_os = "linux")]
pub mod evdev_helper;
mod settings;
mod shortcut;
mod state;
mod tray;

use base64::Engine;
use clipboard::ClipboardItem;
use image::ImageEncoder;
use settings::{Settings, SettingsPatch};
use state::AppState;
use std::sync::atomic::{AtomicU64, Ordering};
use tauri::{AppHandle, Emitter, Manager};

#[tauri::command]
fn get_history(state: tauri::State<'_, AppState>) -> Vec<ClipboardItem> {
    state.history.lock().clone()
}

#[tauri::command]
fn copy_to_clipboard(state: tauri::State<'_, AppState>, id: usize) -> Result<(), String> {
    let history = state.history.lock();
    clipboard::copy_item_to_clipboard(&history, id)
}

#[tauri::command]
fn delete_item(state: tauri::State<'_, AppState>, id: usize) {
    let mut history = state.history.lock();
    if let Some(pos) = history.iter().position(|item| item.id == id) {
        let removed = history.remove(pos);
        clipboard::delete_image_file(&removed.image_path);
    }
    clipboard::save_history(&history);
}

#[tauri::command]
fn clear_history(state: tauri::State<'_, AppState>) {
    let mut history = state.history.lock();
    for item in history.iter() {
        clipboard::delete_image_file(&item.image_path);
    }
    history.clear();
    clipboard::save_history(&history);
}

/// Load an item's image as a `data:image/png;base64,...` URL, on demand.
/// Only the currently visible images are fetched, keeping memory low.
#[tauri::command]
fn get_image_data(state: tauri::State<'_, AppState>, id: usize) -> Option<String> {
    let rel = {
        let history = state.history.lock();
        history
            .iter()
            .find(|i| i.id == id)
            .and_then(|i| i.image_path.clone())
    }?;
    let bytes = clipboard::read_image_file(&rel)?;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
    Some(format!("data:image/png;base64,{}", b64))
}

#[tauri::command]
fn get_settings() -> Settings {
    settings::load_settings()
}

#[tauri::command]
fn save_settings_cmd(settings: Settings) {
    if let Err(e) = settings::save_settings(&settings) {
        log::write_log(&format!("save_settings_cmd failed: {}", e));
    }
}

#[tauri::command]
fn update_settings(app: tauri::AppHandle, partial: serde_json::Value) -> Result<Settings, String> {
    // Single type-safe extraction step: deserialize the payload into a patch
    // struct instead of hand-peeling each key out of the JSON `Value`.
    let patch: SettingsPatch = serde_json::from_value(partial)
        .map_err(|e| format!("无效的设置格式: {}", e))?;
    let mut current = settings::load_settings();

    // Plain fields: apply directly, no validation needed.
    if let Some(v) = patch.close_to_tray {
        current.close_to_tray = v;
    }
    if let Some(v) = patch.auto_start {
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
        if v >= consts::MIN_ZOOM_LEVEL && v <= consts::MAX_ZOOM_LEVEL {
            current.zoom_level = v;
        }
    }
    if let Some(v) = patch.retention_days {
        if v <= 365 {
            current.retention_days = v;
        }
    }
    if let Some(v) = patch.window_width {
        if v >= 320 && v <= 9999 {
            current.window_width = v;
        }
    }
    if let Some(v) = patch.window_height {
        if v >= 400 && v <= 9999 {
            current.window_height = v;
        }
    }

    // Side-effecting fields: validate, then fire the OS-level effect.
    if let Some(v) = patch.hotkey {
        if shortcut::validate_shortcut(&v) {
            current.hotkey = v.clone();
            // Register new shortcut immediately
            let _ = shortcut::register_global_shortcut(&app, &v);
        } else {
            return Err(format!("无效的快捷键格式: {}", v));
        }
    }
    if let Some(v) = patch.double_tap_key {
        let valid_keys = ["", "Ctrl", "Shift", "Alt"];
        if !valid_keys.contains(&v.as_str()) {
            return Err(format!("无效的双击键: {}", v));
        }
        let old = current.double_tap_key.clone();
        current.double_tap_key = v.clone();
        if old != v {
            shortcut::stop_and_wait_double_tap_listener(2000);
            if !v.is_empty() {
                // The listener callback only sends `()` over the channel;
                // the resident worker thread (spawned at startup) performs
                // the actual window raise. No thread per double-tap.
                let key = v.clone();
                let tx = app.state::<AppState>().window_action_tx.clone();
                let app_clone = app.clone();
                std::thread::spawn(move || {
                    if let Err(e) = shortcut::start_double_tap_listener(&key, move || {
                        let _ = tx.send(());
                    }) {
                        log::write_log(&format!("Failed to restart double tap listener: {}", e));
                    }
                });
                spawn_helper_status_monitor(app_clone);
            }
        }
    }

    settings::save_settings(&current).map_err(|e| format!("保存设置失败: {}", e))?;
    Ok(current)
}

#[tauri::command]
fn validate_hotkey(hotkey: String) -> bool {
    shortcut::validate_shortcut(&hotkey)
}

#[tauri::command]
fn toggle_autostart(
    enable: bool,
    manager: tauri::State<'_, tauri_plugin_autostart::AutoLaunchManager>,
) -> Result<(), String> {
    if enable {
        manager.enable().map_err(|e| e.to_string())?;
    } else {
        manager.disable().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn fe_log(message: String) {
    // Truncate to a UTF-8 char boundary so non-ASCII (e.g. Chinese) logs
    // do not panic when slicing by byte index.
    let msg = truncate_char_boundary(&message, 300);
    log::write_log(&format!("[FE] {}", msg));
}

fn truncate_char_boundary(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }
    let mut idx = max_bytes;
    while !s.is_char_boundary(idx) {
        idx -= 1;
    }
    &s[..idx]
}

#[tauri::command]
fn simulate_paste_cmd() -> Result<(), String> {
    shortcut::simulate_paste()
}

/// Show and focus the main window (used by tray, single-instance, and the
/// global shortcut). Sends a request to the resident window-action worker
/// which performs the always-on-top restack dance — single source of truth
/// for "bring window to front".
pub fn focus_main_window(app: &AppHandle) {
    let _ = app.state::<AppState>().window_action_tx.send(());
}

/// Resident worker: drains window-action requests and performs the
/// (slightly heavy, because it must bounce always_on_top + hide/show)
/// window raise. Triggers only send `()` over the channel, so no thread
/// is spawned per double-tap / shortcut.
fn spawn_window_action_worker(app: AppHandle, rx: std::sync::mpsc::Receiver<()>) {
    std::thread::Builder::new()
        .name("window-action-worker".into())
        .spawn(move || {
            for _ in rx {
                if let Some(w) = app.get_webview_window("main") {
                    // Force a restack on compositors that ignore set_focus:
                    // pin on top, hide, then show + focus.
                    let _ = w.set_always_on_top(true);
                    let _ = w.hide();
                    std::thread::sleep(std::time::Duration::from_millis(30));
                    let _ = w.show();
                    let _ = w.set_focus();
                }
                std::thread::sleep(std::time::Duration::from_millis(500));
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.set_always_on_top(false);
                }
            }
        })
        .ok();
}

/// Monitor the evdev helper connection and emit `helper-status` so the UI
/// can show whether Linux double-tap is authorized.
fn spawn_helper_status_monitor(app: AppHandle) {
    std::thread::Builder::new()
        .name("helper-status-monitor".into())
        .spawn(move || {
            let mut was = false;
            let my_gen = shortcut::listener_generation();
            loop {
                std::thread::sleep(std::time::Duration::from_millis(200));
                if shortcut::listener_generation() != my_gen {
                    break;
                }
                let now = shortcut::is_helper_connected();
                if now != was {
                    was = now;
                    let _ = app.emit("helper-status", now);
                }
            }
        })
        .ok();
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

    // Channel feeding the single resident window-action worker (see
    // `spawn_window_action_worker`). Triggers push `()` instead of
    // spawning their own thread.
    let (window_action_tx, window_action_rx) = std::sync::mpsc::channel::<()>();

    let state = AppState {
        history: std::sync::Arc::new(parking_lot::Mutex::new(history)),
        counter: std::sync::Arc::new(parking_lot::Mutex::new(counter)),
        window_action_tx,
    };

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            crate::focus_main_window(app);
        }))
        .manage(state)
        .setup(move |app| {
            log::write_log("setup start");

            // Spawn the single resident window-action worker once.
            crate::spawn_window_action_worker(app.handle().clone(), window_action_rx);

            log::write_log("building tray icon");
            if let Err(e) = tray::setup(app) {
                log::write_log(&format!("Failed to setup tray: {}", e));
            }

            // Explicitly set the window icon from 256x256 PNG
            // This bypasses tauri-build default_window_icon() which may not
            // correctly decode .ico files for the taskbar/alt-tab icon on Windows.
            if let Some(window) = app.get_webview_window("main") {
                if let Ok(img) = image::load_from_memory(include_bytes!("../icons/128x128@2x.png")) {
                    let rgba = img.into_rgba8();
                    let (w, h) = rgba.dimensions();
                    let raw = rgba.into_raw();
                    let icon = tauri::image::Image::new(&raw, w, h);
                    let _ = window.set_icon(icon);
                }
            }

            let s = settings::load_settings();
            log::write_log(&format!("Startup settings: hotkey={}, retention={}d, double_tap={}, silent={}", s.hotkey, s.retention_days, s.double_tap_key, s.silent_start));
            if let Err(e) = shortcut::register_global_shortcut(app.handle(), &s.hotkey) {
                log::write_log(&format!("Failed to register global shortcut: {}", e));
            }

            // Configure autostart based on settings
            use tauri_plugin_autostart::ManagerExt;
            let autostart_manager = app.handle().autolaunch();
            if s.auto_start {
                let _ = autostart_manager.enable();
            } else {
                let _ = autostart_manager.disable();
            }

            if let Some(window) = app.get_webview_window("main") {
               // Restore saved window size only if user had previously resized it.
               // Resize event saves physical size, so restore with PhysicalSize
               // to avoid compounding growth from logical↔physical mismatch.
                if s.window_user_resized {
                   let _ = window.set_size(tauri::PhysicalSize::new(s.window_width, s.window_height));
               }

                // Always handle CloseRequested so the native close button
                // respects the (possibly changed) "close to tray" setting.
                let app_handle = app.handle().clone();
                window.on_window_event(move |event| {
                    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                        let close_to_tray = settings::load_settings().close_to_tray;
                        if close_to_tray {
                            api.prevent_close();
                            if let Some(win) = app_handle.get_webview_window("main") {
                                let _ = win.hide();
                            }
                        }
                    }
                });

                // Save window size on resize (throttled to 500ms)
                let last_save = AtomicU64::new(0);
                window.on_window_event(move |event| {
                   if let tauri::WindowEvent::Resized(size) = event {
                       let now = std::time::SystemTime::now()
                           .duration_since(std::time::UNIX_EPOCH)
                           .unwrap_or_default()
                           .as_millis() as u64;
                       if now.saturating_sub(last_save.load(Ordering::Relaxed)) > 500 {
                           let mut s = settings::load_settings();
                           s.window_width = size.width;
                           s.window_height = size.height;
                            s.window_user_resized = true;
                           if let Err(e) = settings::save_settings(&s) {
                               log::write_log(&format!("Failed to save window size: {}", e));
                            }
                            last_save.store(now, Ordering::Relaxed);
                        }
                    }
                });
            }
            // Silent start: hide window to tray on launch
            if s.silent_start {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.hide();
                    log::write_log("Silent start: window hidden");
                }
            }

            let app_handle = app.handle().clone();
            let state = app.state::<AppState>();

            // Force rounded corners on Windows 11 via DWM
            #[cfg(target_os = "windows")]
            if let Some(window) = app.get_webview_window("main") {
                if let Ok(hwnd) = window.hwnd() {
                    let corner_pref = windows::Win32::Graphics::Dwm::DWMWCP_ROUND;
                    unsafe {
                        windows::Win32::Graphics::Dwm::DwmSetWindowAttribute(
                            hwnd,
                            windows::Win32::Graphics::Dwm::DWMWA_WINDOW_CORNER_PREFERENCE,
                            &corner_pref as *const _ as *const std::ffi::c_void,
                            std::mem::size_of_val(&corner_pref) as u32,
                        ).ok();
                    }
                }
            }
            let hist = state.history.clone();
            let cnt = state.counter.clone();
            log::write_log("spawning clipboard poll thread");

            // 启动时清理过期记录
            let retention = s.retention_days;
            clean_expired_history(app.handle(), &hist, retention);

            std::thread::spawn(move || {
                poll_clipboard(app_handle, hist, cnt);
            });

            // Start double-tap listener if configured. Its callback only
            // sends a `()` over the channel; the resident worker thread
            // (spawned above) performs the actual window raise. Avoids
            // spawning a thread per double-tap.
            if !s.double_tap_key.is_empty() {
                let key = s.double_tap_key.clone();
                // `state` was already moved into `.manage(state)` above, so
                // fetch the sender through the app handle instead.
                let tx = app.state::<AppState>().window_action_tx.clone();
                std::thread::spawn(move || {
                    if let Err(e) = shortcut::start_double_tap_listener(&key, move || {
                        let _ = tx.send(());
                    }) {
                        log::write_log(&format!("Failed to start double tap listener: {}", e));
                    }
                });
                // Start the helper-status monitor on startup too, so the UI's
                // "authorized / needs authorization" indicator updates without
                // requiring the user to change the setting first.
                spawn_helper_status_monitor(app.handle().clone());
            }

            log::write_log("setup complete, app running");
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_history,
            copy_to_clipboard,
            delete_item,
            clear_history,
            get_settings,
            save_settings_cmd,
            update_settings,
            validate_hotkey,
            toggle_autostart,
            fe_log,
            simulate_paste_cmd,
            get_image_data,
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
    let mut last_clean_time = std::time::Instant::now();
    let mut last_save = std::time::Instant::now();
    let save_interval = std::time::Duration::from_millis(400);
    let mut pending_save = false;

    loop {
        std::thread::sleep(std::time::Duration::from_millis(500));

        // Flush any pending debounced save once the interval has elapsed.
        if pending_save && last_save.elapsed() >= save_interval {
            {
                let h = state.lock();
                clipboard::save_history(&h);
            }
            last_save = std::time::Instant::now();
            pending_save = false;
        }

        // 每小时清理一次过期记录
        if last_clean_time.elapsed().as_secs() >= 3600 {
            let retention = settings::load_settings().retention_days;
            clean_expired_history(&app_handle, &state, retention);
            last_clean_time = std::time::Instant::now();
        }

        if let Ok(text) = clipboard.get_text() {
            let text = text.trim().to_string();
            if !text.is_empty() {
                let html_content = clipboard.get().html().ok();
                let hash = clipboard::simple_hash(&text);
                if hash != last_text_hash {
                    last_text_hash = hash;
                    last_image_hash = 0;

                    // If we just wrote this to the clipboard ourselves (the user
                    // clicked "copy" on an existing item), don't re-record it.
                    let self_hash = clipboard::take_self_set_hash();
                    if self_hash != 0 && self_hash == hash {
                        continue;
                    }

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
                        timestamp: chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string(),
                        preview: clipboard::make_preview(&text),
                        char_count: text.chars().count(),
                        image_path: None,
                        image_width: None,
                        image_height: None,
                        html_content,
                    };

                    {
                        let mut history = state.lock();
                        history.insert(0, item);
                        if history.len() > consts::MAX_HISTORY {
                            // Drop the tail beyond the cap and delete their image files.
                            let excess = history.split_off(consts::MAX_HISTORY);
                            for it in &excess {
                                clipboard::delete_image_file(&it.image_path);
                            }
                        }
                        // Debounced persist: flush immediately if the interval has
                        // elapsed, otherwise mark pending for the loop-top flush.
                        let now = std::time::Instant::now();
                        if now.duration_since(last_save) >= save_interval {
                            clipboard::save_history(&history);
                            last_save = now;
                            pending_save = false;
                        } else {
                            pending_save = true;
                        }
                        let _ = app_handle.emit(
                            "clipboard-changed",
                            &history[..std::cmp::min(5, history.len())],
                        );
                    }
                }
            }
        }

        if let Ok(img) = clipboard.get_image() {
            let img_hash_value = clipboard::img_hash(&img);
            if img_hash_value != last_image_hash {
                last_image_hash = img_hash_value;
                last_text_hash = 0;

                // If we just wrote this image ourselves, don't re-record it.
                let self_hash = clipboard::take_self_set_hash();
                if self_hash != 0 && self_hash == img_hash_value {
                    continue;
                }

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

                let id = {
                    let mut c = counter.lock();
                    *c += 1;
                    *c
                };

                let preview = format!("图片 {}x{}", img.width, img.height);

                // Externalize the image: write a PNG file and store only the path.
                let image_path = clipboard::save_image_file(id, &png_bytes);

                let item = ClipboardItem {
                    id,
                    content: preview.clone(),
                    content_type: "image".to_string(),
                    timestamp: chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string(),
                    preview,
                    char_count: png_bytes.len(),
                    image_path,
                    image_width: Some(img.width as u32),
                    image_height: Some(img.height as u32),
                    html_content: None,
                };

                {
                    let mut history = state.lock();
                    history.insert(0, item);
                    if history.len() > consts::MAX_HISTORY {
                        // Drop the tail beyond the cap and delete their image files.
                        let excess = history.split_off(consts::MAX_HISTORY);
                        for it in &excess {
                            clipboard::delete_image_file(&it.image_path);
                        }
                    }
                    // Debounced persist: flush immediately if the interval has
                    // elapsed, otherwise mark pending for the loop-top flush.
                    let now = std::time::Instant::now();
                    if now.duration_since(last_save) >= save_interval {
                        clipboard::save_history(&history);
                        last_save = now;
                        pending_save = false;
                    } else {
                        pending_save = true;
                    }
                    let _ = app_handle.emit(
                        "clipboard-changed",
                        &history[..std::cmp::min(5, history.len())],
                    );
                }
            }
        }
    }
}

fn clean_expired_history(
    app: &AppHandle,
    state: &std::sync::Arc<parking_lot::Mutex<Vec<ClipboardItem>>>,
    retention_days: u32,
) {
    if retention_days == 0 {
        return;
    }

    let cutoff = chrono::Local::now()
        .checked_sub_signed(chrono::Duration::days(retention_days as i64))
        .unwrap();

    let mut history = state.lock();
    let before = history.len();
    let mut removed_images: Vec<Option<String>> = Vec::new();
    history.retain(|item| {
        let keep = if let Some(dt) = clipboard::parse_timestamp(&item.timestamp) {
            dt >= cutoff.naive_local()
        } else {
            true
        };
        if !keep {
            removed_images.push(item.image_path.clone());
        }
        keep
    });
    if history.len() != before {
        // Emit the full remaining history so the frontend can reconcile items
        // removed anywhere in the list (the incremental top-5 `clipboard-changed`
        // event cannot convey deletions beyond the head).
        let snapshot = history.clone();
        clipboard::save_history(&history);
        let cleaned = before - history.len();
        drop(history);
        let _ = app.emit("history-replace", snapshot);
        for path in &removed_images {
            clipboard::delete_image_file(path);
        }
        log::write_log(&format!("Cleaned {} expired history items", cleaned));
    }
}
