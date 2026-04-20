use std::sync::Arc;
use std::thread;
use std::time::Duration;

use arboard::Clipboard;
use parking_lot::Mutex;
use tauri::AppHandle;

use crate::clipboard;
use crate::clipboard::ClipboardItem;
use crate::log;
use crate::state::AppState;

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

pub fn start_polling(
    app_handle: AppHandle,
    state: Arc<Mutex<Vec<ClipboardItem>>>,
    counter: Arc<Mutex<usize>>,
) {
    let state_for_thread = Arc::new(Mutex::new(state.inner().clone()));

    thread::spawn(move || {
        let mut clipboard = match Clipboard::new() {
            Ok(c) => c,
            Err(_) => return,
        };

        let mut last_text_hash: u64 = 0;
        let mut last_image_hash: u64 = 0;

        loop {
            thread::sleep(Duration::from_millis(500));

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

                        let mut history = state.lock();
                        history.insert(0, item);
                        if history.len() > crate::consts::MAX_HISTORY {
                            history.truncate(crate::consts::MAX_HISTORY);
                        }
                        clipboard::save_history(&history);
                        let _ = app_handle.emit(
                            "clipboard-changed",
                            &history[..std::cmp::min(5, history.len())],
                        );
                    }
                }
            }

            if let Ok(img) = clipboard.get_image() {
                let img_hash_value = img_hash(&img);
                if img_hash_value != last_image_hash {
                    last_image_hash = img_hash_value;
                    last_text_hash = 0;

                    if img.bytes.len() > crate::consts::MAX_IMAGE_SIZE {
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
                        timestamp: chrono::Local::now().format("%H:%M:%S").to_string(),
                        preview,
                        char_count: png_bytes.len(),
                        image_data: Some(b64),
                        image_width: Some(img.width as u32),
                        image_height: Some(img.height as u32),
                        html_content: None,
                    };

                    let mut history = state.lock();
                    history.insert(0, item);
                    if history.len() > crate::consts::MAX_HISTORY {
                        history.truncate(crate::consts::MAX_HISTORY);
                    }
                    clipboard::save_history(&history);
                    let _ = app_handle.emit(
                        "clipboard-changed",
                        &history[..std::cmp::min(5, history.len())],
                    );
                }
            }
        }
    });
}
