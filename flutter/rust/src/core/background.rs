//! Background tasks.
//!
//! Three resident threads:
//!   1. clipboard capture — Wayland selection events on Linux, arboard polling
//!      on Windows/macOS
//!   2. `helper-status-monitor` — 200ms poll of the evdev helper connection
//!      state, emits on change
//!   3. `clean-expired`      — runs once at startup, then hourly, dropping
//!      items older than `retention_days`
//!
//! These jobs use `std::thread`, `mpsc`, and sleep loops because they perform no
//! async IO; this also avoids an unnecessary Tokio runtime.

use crate::core::clipboard_engine::ClipboardItem;
use crate::core::{clipboard_engine, events, log, state};
#[cfg(not(target_os = "linux"))]
use crate::core::{consts, sanitize};
#[cfg(not(target_os = "linux"))]
use image::ImageEncoder;
use parking_lot::Mutex;
use std::sync::Arc;
use std::time::Duration;

/// Decode the BMP produced by the Windows `CF_BITMAP` fallback into the same
/// RGBA payload returned by arboard. Kept platform-neutral so the decoder can
/// be covered by unit tests on non-Windows builders.
#[cfg(any(target_os = "windows", all(test, not(target_os = "linux"))))]
fn decode_windows_bitmap(bytes: &[u8]) -> Result<arboard::ImageData<'static>, String> {
    let image = image::load_from_memory_with_format(bytes, image::ImageFormat::Bmp)
        .map_err(|error| format!("failed to decode CF_BITMAP: {error}"))?
        .into_rgba8();
    let (width, height) = image.dimensions();
    Ok(arboard::ImageData {
        width: width as usize,
        height: height as usize,
        bytes: image.into_raw().into(),
    })
}

/// arboard's Windows reader accepts registered PNG and CF_DIBV5, but PixPin
/// can publish a DIB variant that its BMP decoder rejects. PixPin also exposes
/// CF_BITMAP; asking GDI to materialize that handle as a plain RGB BMP gives us
/// a reliable native fallback without spawning PowerShell every 500 ms.
#[cfg(target_os = "windows")]
fn read_windows_clipboard_image_fallback() -> Result<Option<arboard::ImageData<'static>>, String> {
    use clipboard_win::formats::{Bitmap, CF_BITMAP, CF_DIB, CF_DIBV5};

    let has_bitmap = clipboard_win::is_format_avail(CF_BITMAP);
    let has_dib = clipboard_win::is_format_avail(CF_DIB);
    let has_dibv5 = clipboard_win::is_format_avail(CF_DIBV5);
    if !has_bitmap && !has_dib && !has_dibv5 {
        return Ok(None);
    }
    if !has_bitmap {
        return Err(format!(
            "image formats present (CF_DIB={has_dib}, CF_DIBV5={has_dibv5}) but CF_BITMAP is unavailable"
        ));
    }

    let bmp: Vec<u8> = clipboard_win::get_clipboard(Bitmap)
        .map_err(|error| format!("failed to materialize CF_BITMAP through GDI: {error}"))?;
    decode_windows_bitmap(&bmp).map(Some)
}

#[cfg(all(not(target_os = "windows"), not(target_os = "linux")))]
fn read_windows_clipboard_image_fallback() -> Result<Option<arboard::ImageData<'static>>, String> {
    Ok(None)
}

#[cfg(not(target_os = "linux"))]
fn read_clipboard_image(
    clipboard: &mut arboard::Clipboard,
) -> Result<Option<arboard::ImageData<'static>>, String> {
    match clipboard.get_image() {
        Ok(image) => Ok(Some(image)),
        Err(primary_error) => match read_windows_clipboard_image_fallback() {
            Ok(Some(image)) => Ok(Some(image)),
            Ok(None) => Ok(None),
            Err(fallback_error) => Err(format!(
                "Clipboard image read failed: arboard={primary_error}; fallback={fallback_error}"
            )),
        },
    }
}

/// Spawn all three background tasks. Called once from `init_app_state`.
pub fn spawn_all(history: Arc<Mutex<Vec<ClipboardItem>>>, counter: Arc<Mutex<usize>>) {
    // 3. clean-expired — runs once immediately, then hourly. Spawned first so
    // the startup sweep lands before the first poll tick records anything new.
    let clean_history = history.clone();
    if let Err(error) = std::thread::Builder::new()
        .name("clean-expired".into())
        .spawn(move || clean_expired_loop(clean_history))
    {
        log::write_log(&format!("Failed to spawn clean-expired thread: {error}"));
    }

    // 2. helper-status monitor.
    if let Err(error) = std::thread::Builder::new()
        .name("helper-status-monitor".into())
        .spawn(helper_status_monitor)
    {
        log::write_log(&format!(
            "Failed to spawn helper-status-monitor thread: {error}"
        ));
    }

    // 1. clipboard capture.
    #[cfg(target_os = "linux")]
    let capture = std::thread::Builder::new()
        .name("wayland-clipboard-watch".into())
        .spawn(move || crate::core::wayland_clipboard::run(history, counter));

    #[cfg(not(target_os = "linux"))]
    let capture = std::thread::Builder::new()
        .name("clipboard-poll".into())
        .spawn(move || poll_clipboard(history, counter));

    if let Err(error) = capture {
        log::write_log(&format!(
            "Failed to spawn clipboard capture thread: {error}"
        ));
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
        let retention = state::st().settings.lock().retention_days;
        clean_expired_history(&history, retention);
        std::thread::sleep(Duration::from_secs(3600));
    }
}

fn clean_expired_history(history: &Arc<Mutex<Vec<ClipboardItem>>>, retention_days: u32) {
    if retention_days == 0 {
        return;
    }

    let Some(cutoff) =
        chrono::Local::now().checked_sub_signed(chrono::Duration::days(i64::from(retention_days)))
    else {
        log::write_log("Retention cutoff overflowed; skipping cleanup");
        return;
    };

    let mut history = history.lock();
    let before = history.len();
    let mut next = history.clone();
    let mut removed_images: Vec<Option<String>> = Vec::new();
    next.retain(|item| {
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
    if next.len() != before {
        // Emit the full remaining history so the frontend can reconcile items
        // removed anywhere in the list (the incremental top-5 stream cannot
        // convey deletions beyond the head).
        if let Err(e) = clipboard_engine::save_history(&next) {
            log::write_log(&format!("Failed to persist expired-history cleanup: {}", e));
            return;
        }
        let cleaned = before - next.len();
        *history = next;
        let snapshot = history.clone();
        drop(history);
        events::emit_history_replace(snapshot);
        for path in &removed_images {
            clipboard_engine::delete_image_file(path);
        }
        log::write_log(&format!("Cleaned {} expired history items", cleaned));
    }
}

pub(crate) fn next_item_id(counter: &Arc<Mutex<usize>>) -> Result<usize, String> {
    let mut counter = counter.lock();
    let next = counter
        .checked_add(1)
        .ok_or_else(|| "Clipboard history ID counter exhausted".to_string())?;
    *counter = next;
    Ok(next)
}

#[cfg(not(target_os = "linux"))]
fn poll_clipboard(history: Arc<Mutex<Vec<ClipboardItem>>>, counter: Arc<Mutex<usize>>) {
    let mut retry_delay = Duration::from_secs(1);
    let mut clipboard = loop {
        match arboard::Clipboard::new() {
            Ok(clipboard) => break clipboard,
            Err(error) => {
                log::write_log(&format!(
                    "Failed to open clipboard; retrying in {}s: {error}",
                    retry_delay.as_secs()
                ));
                std::thread::sleep(retry_delay);
                retry_delay = (retry_delay * 2).min(Duration::from_secs(30));
            }
        }
    };

    let mut last_text_hash: u64 = 0;
    let mut last_image_hash: u64 = 0;
    let mut last_image_read_error: Option<String> = None;

    loop {
        std::thread::sleep(Duration::from_millis(500));

        // Some applications publish both bitmap and text representations for
        // one clipboard operation. Treat the bitmap as the primary format so a
        // single copy produces exactly one history entry.
        let current_image = match read_clipboard_image(&mut clipboard) {
            Ok(image) => {
                last_image_read_error = None;
                image
            }
            Err(error) => {
                if last_image_read_error.as_deref() != Some(error.as_str()) {
                    log::write_log(&error);
                    last_image_read_error = Some(error);
                }
                None
            }
        };

        if let Ok(text) = clipboard.get_text() {
            // Preserve the clipboard payload byte-for-byte. Trimming here
            // corrupted indentation, trailing newlines, and editor selections;
            // only use trim for the empty/whitespace-only decision and preview.
            if !text.trim().is_empty() && current_image.is_none() {
                if text.len() > consts::MAX_TEXT_SIZE {
                    let hash = clipboard_engine::simple_hash(&text);
                    if hash != last_text_hash {
                        last_text_hash = hash;
                        log::write_log(&format!(
                            "Text clipboard payload too large ({} bytes), skipping",
                            text.len()
                        ));
                    }
                    continue;
                }
                let html_content = clipboard.get().html().ok().and_then(|html| {
                    if html.len() > consts::MAX_HTML_SIZE {
                        log::write_log(&format!(
                            "HTML clipboard payload too large ({} bytes), storing plain text only",
                            html.len()
                        ));
                        return None;
                    }
                    // Sanitize at the add-stage (decision: ammonia in Rust).
                    // If everything was stripped (e.g. only a <script>),
                    // treat as no rich text so content_type falls back.
                    let s = sanitize::sanitize_html(&html);
                    if s.is_empty() {
                        None
                    } else {
                        Some(s)
                    }
                });
                let self_hash = clipboard_engine::simple_hash(&text);
                let content_hash =
                    clipboard_engine::text_content_hash(&text, html_content.as_deref());
                let observation_hash = clipboard_engine::simple_hash(&content_hash);
                if observation_hash != last_text_hash {
                    // If we just wrote this to the clipboard ourselves (the user
                    // clicked "copy" on an existing item), don't re-record it.
                    let pending_self_hash = clipboard_engine::take_self_set_hash();
                    if pending_self_hash != 0 && pending_self_hash == self_hash {
                        last_text_hash = observation_hash;
                        continue;
                    }

                    let id = match next_item_id(&counter) {
                        Ok(id) => id,
                        Err(error) => {
                            log::write_log(&error);
                            continue;
                        }
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
                        file_paths: None,
                        content_hash: Some(content_hash),
                    };

                    let result = {
                        let mut history = history.lock();
                        clipboard_engine::commit_item(&mut history, item).map(|removed| {
                            let top = history[..std::cmp::min(5, history.len())].to_vec();
                            // Trimming can remove multiple tail entries while
                            // the list is still below the 500-item UI cap. A
                            // top-5 delta cannot describe those deletions.
                            let full = (!removed.is_empty()).then(|| history.clone());
                            (top, full, removed)
                        })
                    };
                    match result {
                        Ok((top, full, removed)) => {
                            // Mark observed only after the snapshot is durable.
                            // A transient storage failure is retried while the
                            // clipboard still contains the same payload.
                            last_text_hash = observation_hash;
                            for image in removed {
                                clipboard_engine::delete_image_file(&image);
                            }
                            if let Some(full) = full {
                                events::emit_history_replace(full);
                            } else {
                                events::emit_clipboard_changed(top);
                            }
                        }
                        Err(error) => {
                            log::write_log(&format!("Failed to save clipboard history: {error}"));
                        }
                    }
                }
            }
        }

        if let Some(img) = current_image {
            let img_hash_value = clipboard_engine::img_hash(&img);
            if img_hash_value != last_image_hash {
                // If we just wrote this image ourselves, don't re-record it.
                let self_hash = clipboard_engine::take_self_set_hash();
                if self_hash != 0 && self_hash == img_hash_value {
                    last_image_hash = img_hash_value;
                    continue;
                }

                if img.bytes.len() > consts::MAX_IMAGE_SIZE {
                    last_image_hash = img_hash_value;
                    log::write_log(&format!(
                        "Image too large ({} bytes), skipping",
                        img.bytes.len()
                    ));
                    continue;
                }

                let (Ok(width), Ok(height)) = (u32::try_from(img.width), u32::try_from(img.height))
                else {
                    last_image_hash = img_hash_value;
                    log::write_log("Image dimensions exceed supported range");
                    continue;
                };
                let rgba_img = image::RgbaImage::from_raw(width, height, img.bytes.to_vec());
                let rgba_img = match rgba_img {
                    Some(img) => img,
                    None => {
                        last_image_hash = img_hash_value;
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
                    last_image_hash = img_hash_value;
                    log::write_log(&format!("Failed to encode image to PNG: {:?}", e));
                    continue;
                }

                let content_hash = clipboard_engine::image_content_hash(&png_bytes);

                let id = match next_item_id(&counter) {
                    Ok(id) => id,
                    Err(error) => {
                        log::write_log(&error);
                        continue;
                    }
                };

                let preview = format!("图片 {}x{}", img.width, img.height);

                // The image must be durable before its history reference can
                // be committed. Duplicate capture files are removed after the
                // existing item has been reordered successfully.
                let image_path = {
                    let Some(path) = clipboard_engine::save_image_file(id, &png_bytes) else {
                        continue;
                    };
                    Some(path)
                };
                let rollback_image_path = image_path.clone();

                let item = ClipboardItem {
                    id,
                    content: preview.clone(),
                    content_type: "image".to_string(),
                    timestamp: chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string(),
                    preview,
                    char_count: png_bytes.len(),
                    image_path,
                    image_width: Some(width),
                    image_height: Some(height),
                    html_content: None,
                    file_paths: None,
                    content_hash: Some(content_hash),
                };

                let result = {
                    let mut history = history.lock();
                    clipboard_engine::commit_item(&mut history, item).map(|removed| {
                        let top = history[..std::cmp::min(5, history.len())].to_vec();
                        let full = (!removed.is_empty()).then(|| history.clone());
                        (top, full, removed)
                    })
                };
                match result {
                    Ok((top, full, removed)) => {
                        last_image_hash = img_hash_value;
                        for image in removed {
                            clipboard_engine::delete_image_file(&image);
                        }
                        if let Some(full) = full {
                            events::emit_history_replace(full);
                        } else {
                            events::emit_clipboard_changed(top);
                        }
                    }
                    Err(error) => {
                        // The item was never exposed; remove its unreferenced
                        // image file as part of rolling the transaction back.
                        clipboard_engine::delete_image_file(&rollback_image_path);
                        log::write_log(&format!("Failed to save clipboard history: {error}"));
                    }
                }
            }
        }
    }
}

#[cfg(all(test, not(target_os = "linux")))]
mod tests {
    use super::decode_windows_bitmap;

    #[test]
    fn decodes_gdi_bitmap_fallback_payload() {
        let mut bytes = Vec::new();
        image::codecs::bmp::BmpEncoder::new(&mut bytes)
            .encode(&[0x11, 0x22, 0x33], 1, 1, image::ExtendedColorType::Rgb8)
            .expect("fixture should encode");
        let image = decode_windows_bitmap(&bytes).expect("BMP should decode");
        assert_eq!((image.width, image.height), (1, 1));
        assert_eq!(image.bytes.as_ref(), &[0x11, 0x22, 0x33, 0xff]);
    }
}
