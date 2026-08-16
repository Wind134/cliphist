//! Background tasks.
//!
//! Four resident threads, matching the old Tauri stack's worker set:
//!   1. `clipboard-poll`     — 500ms arboard polling, dedup, image/rich capture
//!   2. `window-action-worker` — drains window-action requests, emits a
//!      `WindowActionKind` event for Dart (the dance itself is Dart-side, M3)
//!   3. `helper-status-monitor` — 200ms poll of the evdev helper connection
//!      state, emits on change
//!   4. `clean-expired`      — runs once at startup, then hourly, dropping
//!      items older than `retention_days`
//!
//! Deviation from the plan: the plan called for a tokio runtime, but the old
//! stack is plain `std::thread` + `mpsc` + sleep loops with no async IO, so a
//! faithful port stays on `std::thread` and avoids a tokio dependency and any
//! FRB-runtime friction. The four-task shape is unchanged.

use crate::core::clipboard_engine::ClipboardItem;
use crate::core::{clipboard_engine, consts, events, log, sanitize, settings_store, state};
use image::ImageEncoder;
use parking_lot::Mutex;
use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Spawn all four background tasks. Called once from `init_app_state`.
pub fn spawn_all(
    history: Arc<Mutex<Vec<ClipboardItem>>>,
    counter: Arc<Mutex<usize>>,
    window_action_rx: mpsc::Receiver<()>,
) {
    // 4. clean-expired — runs once immediately, then hourly. Spawned first so
    // the startup sweep lands before the first poll tick records anything new.
    let clean_history = history.clone();
    std::thread::Builder::new()
        .name("clean-expired".into())
        .spawn(move || clean_expired_loop(clean_history))
        .ok();

    // 2. window-action worker.
    std::thread::Builder::new()
        .name("window-action-worker".into())
        .spawn(move || window_action_worker(window_action_rx))
        .ok();

    // 3. helper-status monitor.
    std::thread::Builder::new()
        .name("helper-status-monitor".into())
        .spawn(helper_status_monitor)
        .ok();

    // 1. clipboard poll.
    std::thread::Builder::new()
        .name("clipboard-poll".into())
        .spawn(move || poll_clipboard(history, counter))
        .ok();
}

/// Resident window-action consumer. Each `()` drained from the channel becomes
/// a `WindowActionKind::ShowAndRaise` event; Dart performs the visible dance.
fn window_action_worker(rx: mpsc::Receiver<()>) {
    for () in rx {
        events::emit_window_action(events::WindowActionKind::ShowAndRaise);
    }
}

/// Monitor the evdev-helper / rdev-listener connection and emit on change so
/// the UI can show whether double-tap is authorized. On Linux the flag is the
/// evdev helper's connected state; on Windows/macOS it is the rdev `grab`
/// listener's running state (set true on start, false on stop/error). Either
/// way this thread just watches `is_helper_connected` and pushes deltas.
fn helper_status_monitor() {
    let mut was = false;
    loop {
        std::thread::sleep(Duration::from_millis(200));
        let now = state::is_helper_connected();
        if now != was {
            was = now;
            events::emit_helper_status(now);
        }
    }
}

/// Hourly expired-history sweep. The first iteration runs immediately (startup
/// clean), then sleeps an hour between rounds. Re-reads `retention_days` each
/// round so a settings change takes effect without a restart.
fn clean_expired_loop(history: Arc<Mutex<Vec<ClipboardItem>>>) {
    loop {
        let retention = settings_store::load_settings().retention_days;
        clean_expired_history(&history, retention);
        std::thread::sleep(Duration::from_secs(3600));
    }
}

fn clean_expired_history(history: &Arc<Mutex<Vec<ClipboardItem>>>, retention_days: u32) {
    if retention_days == 0 {
        return;
    }

    let cutoff = chrono::Local::now()
        .checked_sub_signed(chrono::Duration::days(retention_days as i64))
        .unwrap();

    let mut history = history.lock();
    let before = history.len();
    let mut removed_images: Vec<Option<String>> = Vec::new();
    history.retain(|item| {
        let keep = if let Some(dt) = clipboard_engine::parse_timestamp(&item.timestamp) {
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
        // removed anywhere in the list (the incremental top-5 stream cannot
        // convey deletions beyond the head).
        let snapshot = history.clone();
        clipboard_engine::save_history(&history);
        let cleaned = before - history.len();
        drop(history);
        events::emit_history_replace(snapshot);
        for path in &removed_images {
            clipboard_engine::delete_image_file(path);
        }
        log::write_log(&format!("Cleaned {} expired history items", cleaned));
    }
}

fn poll_clipboard(history: Arc<Mutex<Vec<ClipboardItem>>>, counter: Arc<Mutex<usize>>) {
    let mut clipboard = match arboard::Clipboard::new() {
        Ok(c) => c,
        Err(e) => {
            log::write_log(&format!(
                "Failed to open arboard clipboard in poll loop: {}",
                e
            ));
            return;
        }
    };

    let mut last_text_hash: u64 = 0;
    let mut last_image_hash: u64 = 0;
    let mut last_save = Instant::now();
    let save_interval = Duration::from_millis(400);
    let mut pending_save = false;

    loop {
        std::thread::sleep(Duration::from_millis(500));

        // Flush any pending debounced save once the interval has elapsed.
        if pending_save && last_save.elapsed() >= save_interval {
            // Persist while holding the state lock so an older snapshot can
            // never overwrite a newer delete/clear operation.
            clipboard_engine::save_history(&history.lock());
            last_save = Instant::now();
            pending_save = false;
        }

        // Some applications publish both bitmap and text representations for
        // one clipboard operation. Treat the bitmap as the primary format so a
        // single copy produces exactly one history entry.
        let current_image = clipboard.get_image().ok();

        if let Ok(text) = clipboard.get_text() {
            let text = text.trim().to_string();
            if !text.is_empty() && current_image.is_none() {
                let html_content = clipboard.get().html().ok().and_then(|h| {
                    // Sanitize at the add-stage (decision: ammonia in Rust).
                    // If everything was stripped (e.g. only a <script>),
                    // treat as no rich text so content_type falls back.
                    let s = sanitize::sanitize_html(&h);
                    if s.is_empty() {
                        None
                    } else {
                        Some(s)
                    }
                });
                let hash = clipboard_engine::simple_hash(&text);
                if hash != last_text_hash {
                    last_text_hash = hash;

                    // If we just wrote this to the clipboard ourselves (the user
                    // clicked "copy" on an existing item), don't re-record it.
                    let self_hash = clipboard_engine::take_self_set_hash();
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
                        clipboard_engine::get_content_type(&text)
                    };

                    let item = ClipboardItem {
                        id,
                        content: text.clone(),
                        content_type,
                        timestamp: chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string(),
                        preview: clipboard_engine::make_preview(&text),
                        char_count: text.chars().count(),
                        image_path: None,
                        image_width: None,
                        image_height: None,
                        html_content,
                    };

                    let (top, excess_images) = {
                        let mut history = history.lock();
                        history.insert(0, item);
                        let excess_images: Vec<Option<String>> =
                            if history.len() > consts::MAX_HISTORY {
                                let excess = history.split_off(consts::MAX_HISTORY);
                                excess.iter().map(|it| it.image_path.clone()).collect()
                            } else {
                                Vec::new()
                            };
                        let top = history[..std::cmp::min(5, history.len())].to_vec();
                        let now = Instant::now();
                        if now.duration_since(last_save) >= save_interval {
                            // Serialize while the lock is held to preserve mutation order.
                            clipboard_engine::save_history(&history);
                            last_save = now;
                            pending_save = false;
                        } else {
                            pending_save = true;
                        }
                        (top, excess_images)
                    };
                    for img in &excess_images {
                        clipboard_engine::delete_image_file(img);
                    }
                    events::emit_clipboard_changed(top);
                }
            }
        }

        if let Some(img) = current_image {
            let img_hash_value = clipboard_engine::img_hash(&img);
            if img_hash_value != last_image_hash {
                last_image_hash = img_hash_value;

                // If we just wrote this image ourselves, don't re-record it.
                let self_hash = clipboard_engine::take_self_set_hash();
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
                let image_path = clipboard_engine::save_image_file(id, &png_bytes);

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

                let (top, excess_images) = {
                    let mut history = history.lock();
                    history.insert(0, item);
                    let excess_images: Vec<Option<String>> = if history.len() > consts::MAX_HISTORY
                    {
                        let excess = history.split_off(consts::MAX_HISTORY);
                        excess.iter().map(|it| it.image_path.clone()).collect()
                    } else {
                        Vec::new()
                    };
                    let top = history[..std::cmp::min(5, history.len())].to_vec();
                    let now = Instant::now();
                    if now.duration_since(last_save) >= save_interval {
                        clipboard_engine::save_history(&history);
                        last_save = now;
                        pending_save = false;
                    } else {
                        pending_save = true;
                    }
                    (top, excess_images)
                };
                for img in &excess_images {
                    clipboard_engine::delete_image_file(img);
                }
                events::emit_clipboard_changed(top);
            }
        }
    }
}
