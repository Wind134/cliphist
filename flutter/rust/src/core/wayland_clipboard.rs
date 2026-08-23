//! Native Wayland clipboard capture and restore helpers.
//!
//! Clipboard changes arrive through ext-data-control-v1 (falling back to the
//! compatible wlr protocol). Every advertised representation is read from the
//! same selection so text, HTML, PNG and file-list alternatives stay together
//! as one history record.

use crate::core::background::next_item_id;
use crate::core::clipboard_engine::{self, ClipboardItem};
use crate::core::{consts, events, log, sanitize};
use image::{ImageDecoder, ImageEncoder};
use parking_lot::Mutex;
use std::io::Cursor;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use url::Url;
use wl_clipboard_watch::{Config, Event, Selection, Transfer, Watcher};

const TEXT_MIME_TYPES: &[&str] = &[
    "text/plain;charset=utf-8",
    "text/plain;charset=UTF-8",
    "UTF8_STRING",
    "text/plain",
    "TEXT",
    "STRING",
];
const HTML_MIME_TYPES: &[&str] = &["text/html"];
const FILE_MIME_TYPES: &[&str] = &["text/uri-list", "x-special/gnome-copied-files"];
const IMAGE_MIME_TYPES: &[&str] = &["image/png", "image/bmp"];

enum OfferedData {
    Missing,
    Complete { mime_type: String, bytes: Vec<u8> },
    Stale,
}

pub fn run(history: Arc<Mutex<Vec<ClipboardItem>>>, counter: Arc<Mutex<usize>>) {
    let config = Config::new(consts::MAX_IMAGE_SIZE, Duration::from_secs(5))
        .expect("non-zero Wayland clipboard limits");
    let mut retry_delay = Duration::from_secs(1);

    loop {
        let mut watcher = match Watcher::connect_with(config) {
            Ok(watcher) => watcher,
            Err(error) => {
                log::write_log(&format!(
                    "Failed to connect to the Wayland clipboard; retrying in {}s: {error}",
                    retry_delay.as_secs()
                ));
                std::thread::sleep(retry_delay);
                retry_delay = (retry_delay * 2).min(Duration::from_secs(30));
                continue;
            }
        };

        log::write_log(&format!(
            "Watching Wayland clipboard via {}",
            watcher.protocol().interface_name()
        ));
        retry_delay = Duration::from_secs(1);

        loop {
            match watcher.next_event() {
                Ok(Event::Selection(selection)) => {
                    if let Err(error) =
                        capture_selection(&mut watcher, &selection, &history, &counter)
                    {
                        log::write_log(&format!(
                            "Wayland clipboard transfer failed; reconnecting: {error}"
                        ));
                        break;
                    }
                }
                Ok(Event::Cleared) => {}
                Err(error) => {
                    log::write_log(&format!(
                        "Wayland clipboard watcher disconnected; reconnecting: {error}"
                    ));
                    break;
                }
            }
        }
    }
}

fn capture_selection(
    watcher: &mut Watcher,
    selection: &Selection,
    history: &Arc<Mutex<Vec<ClipboardItem>>>,
    counter: &Arc<Mutex<usize>>,
) -> Result<(), String> {
    if selection.mime_types().iter().any(|mime| {
        let mime = mime.to_ascii_lowercase();
        mime.contains("passwordmanagerhint") || mime == "application/x-nspasteboard-concealed-type"
    }) {
        return Ok(());
    }

    let file_offer = receive_first(watcher, selection, FILE_MIME_TYPES)?;
    let text_offer = receive_first(watcher, selection, TEXT_MIME_TYPES)?;
    let html_offer = receive_first(watcher, selection, HTML_MIME_TYPES)?;
    let image_offer = receive_first(watcher, selection, IMAGE_MIME_TYPES)?;
    if matches!(file_offer, OfferedData::Stale)
        || matches!(text_offer, OfferedData::Stale)
        || matches!(html_offer, OfferedData::Stale)
        || matches!(image_offer, OfferedData::Stale)
    {
        return Ok(());
    }

    let file_paths = match file_offer {
        OfferedData::Complete { mime_type, bytes } => match parse_file_offer(&mime_type, &bytes) {
            Ok(paths) if !paths.is_empty() => Some(paths),
            Ok(_) => None,
            Err(error) => {
                log::write_log(&format!("Ignoring invalid Wayland file list: {error}"));
                None
            }
        },
        OfferedData::Missing | OfferedData::Stale => None,
    };

    let mut text = match text_offer {
        OfferedData::Complete { bytes, .. } if bytes.len() <= consts::MAX_TEXT_SIZE => {
            match String::from_utf8(bytes) {
                Ok(text) => text,
                Err(error) => {
                    log::write_log(&format!("Ignoring non-UTF-8 Wayland text: {error}"));
                    String::new()
                }
            }
        }
        OfferedData::Complete { bytes, .. } => {
            log::write_log(&format!(
                "Wayland text payload too large ({} bytes), skipping text representation",
                bytes.len()
            ));
            String::new()
        }
        OfferedData::Missing | OfferedData::Stale => String::new(),
    };

    let html_content = match html_offer {
        OfferedData::Complete { bytes, .. } if bytes.len() <= consts::MAX_HTML_SIZE => {
            String::from_utf8(bytes).ok().and_then(|html| {
                let clean = sanitize::sanitize_html(&html);
                (!clean.is_empty()).then_some(clean)
            })
        }
        OfferedData::Complete { bytes, .. } => {
            log::write_log(&format!(
                "Wayland HTML payload too large ({} bytes), skipping HTML representation",
                bytes.len()
            ));
            None
        }
        OfferedData::Missing | OfferedData::Stale => None,
    };

    let image = match image_offer {
        OfferedData::Complete { mime_type, bytes } => match normalize_image(&mime_type, bytes) {
            Ok(image) => Some(image),
            Err(error) => {
                log::write_log(&format!("Ignoring invalid Wayland image: {error}"));
                None
            }
        },
        OfferedData::Missing | OfferedData::Stale => None,
    };

    // File-list text varies between file managers (paths, URIs, or only file
    // names). Canonical paths make display, search, dedup and later restore
    // consistent.
    if let Some(paths) = file_paths.as_deref() {
        text = paths.join("\n");
    }

    if text.trim().is_empty() && html_content.is_none() && image.is_none() && file_paths.is_none() {
        return Ok(());
    }

    let image_bytes = image.as_ref().map(|image| image.png.as_slice());
    let content_hash = clipboard_engine::content_hash(
        &text,
        html_content.as_deref(),
        image_bytes,
        file_paths.as_deref(),
    );
    let observation_hash = clipboard_engine::simple_hash(&content_hash);
    let self_hash = clipboard_engine::take_self_set_hash();
    if self_hash != 0 && self_hash == observation_hash {
        return Ok(());
    }

    let id = next_item_id(counter)?;
    let (image_width, image_height) = image.as_ref().map_or((None, None), |image| {
        (Some(image.width), Some(image.height))
    });
    let image_path = image
        .as_ref()
        .and_then(|image| clipboard_engine::save_image_file(id, &image.png));
    if image.is_some() && image_path.is_none() {
        return Ok(());
    }
    let rollback_image_path = image_path.clone();

    let content_type = if file_paths.is_some() {
        "files".to_string()
    } else if image.is_some() {
        "image".to_string()
    } else if html_content.is_some() {
        "rich".to_string()
    } else {
        clipboard_engine::get_content_type(&text)
    };
    let preview = if let Some(paths) = file_paths.as_deref() {
        file_preview(paths)
    } else if let Some(image) = image.as_ref() {
        format!("图片 {}x{}", image.width, image.height)
    } else if text.trim().is_empty() {
        "富文本".to_string()
    } else {
        clipboard_engine::make_preview(&text)
    };
    let char_count = if let Some(paths) = file_paths.as_deref() {
        paths.len()
    } else if let Some(image) = image.as_ref() {
        image.png.len()
    } else {
        text.chars().count()
    };

    let item = ClipboardItem {
        id,
        content: text,
        content_type,
        timestamp: chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string(),
        preview,
        char_count,
        image_path,
        image_width,
        image_height,
        html_content,
        file_paths,
        content_hash: Some(content_hash),
    };

    let result = {
        let mut history = history.lock();
        clipboard_engine::commit_item(&mut history, item).map(|removed| {
            let top = history[..history.len().min(5)].to_vec();
            let full = (!removed.is_empty()).then(|| history.clone());
            (top, full, removed)
        })
    };
    match result {
        Ok((top, full, removed)) => {
            for image in removed {
                clipboard_engine::delete_image_file(&image);
            }
            if let Some(full) = full {
                events::emit_history_replace(full);
            } else {
                events::emit_clipboard_changed(top);
            }
            Ok(())
        }
        Err(error) => {
            clipboard_engine::delete_image_file(&rollback_image_path);
            Err(format!("failed to persist clipboard history: {error}"))
        }
    }
}

fn receive_first(
    watcher: &mut Watcher,
    selection: &Selection,
    candidates: &[&str],
) -> Result<OfferedData, String> {
    let offered = candidates.iter().find_map(|candidate| {
        selection
            .mime_types()
            .iter()
            .find(|offered| offered.eq_ignore_ascii_case(candidate))
            .cloned()
    });
    let Some(mime_type) = offered else {
        return Ok(OfferedData::Missing);
    };
    match watcher
        .receive(selection, &mime_type)
        .map_err(|error| error.to_string())?
    {
        Transfer::Complete(bytes) => Ok(OfferedData::Complete { mime_type, bytes }),
        Transfer::Stale => Ok(OfferedData::Stale),
    }
}

fn parse_file_offer(mime_type: &str, bytes: &[u8]) -> Result<Vec<String>, String> {
    if bytes.len() > consts::MAX_FILE_LIST_SIZE {
        return Err(format!("payload is {} bytes", bytes.len()));
    }
    let value = std::str::from_utf8(bytes).map_err(|error| error.to_string())?;
    let mut lines = value.lines();
    if mime_type.eq_ignore_ascii_case("x-special/gnome-copied-files") {
        match lines.next() {
            Some(operation) if operation == "copy" || operation == "cut" => {}
            _ => return Err("missing GNOME copy/cut header".to_string()),
        }
    }

    let mut paths = Vec::new();
    for line in lines {
        let line = line.trim_end_matches('\r').trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let url = Url::parse(line).map_err(|error| format!("invalid URI {line:?}: {error}"))?;
        if url.scheme() != "file" {
            continue;
        }
        let path = url
            .to_file_path()
            .map_err(|_| format!("non-local file URI {line:?}"))?;
        paths.push(path.to_string_lossy().into_owned());
        if paths.len() >= consts::MAX_FILE_COUNT {
            break;
        }
    }
    Ok(paths)
}

pub fn encode_uri_list(paths: &[String]) -> Result<String, String> {
    if paths.is_empty() || paths.len() > consts::MAX_FILE_COUNT {
        return Err("文件列表为空或数量超出限制".to_string());
    }
    let mut encoded = String::new();
    for path in paths {
        let url = Url::from_file_path(Path::new(path))
            .map_err(|_| format!("无法编码本地文件路径: {path}"))?;
        encoded.push_str(url.as_str());
        encoded.push_str("\r\n");
        if encoded.len() > consts::MAX_FILE_LIST_SIZE {
            return Err("文件列表内容超出大小限制".to_string());
        }
    }
    Ok(encoded)
}

struct NormalizedImage {
    png: Vec<u8>,
    width: u32,
    height: u32,
}

fn normalize_image(mime_type: &str, bytes: Vec<u8>) -> Result<NormalizedImage, String> {
    if bytes.len() as u64 > consts::MAX_IMAGE_FILE_SIZE {
        return Err(format!("encoded image is {} bytes", bytes.len()));
    }
    if mime_type.eq_ignore_ascii_case("image/png") {
        let decoder = image::codecs::png::PngDecoder::new(Cursor::new(&bytes))
            .map_err(|error| error.to_string())?;
        let (width, height) = decoder.dimensions();
        validate_image_dimensions(width, height)?;
        // Decode once to reject malformed/truncated streams before persisting.
        image::DynamicImage::from_decoder(decoder).map_err(|error| error.to_string())?;
        return Ok(NormalizedImage {
            png: bytes,
            width,
            height,
        });
    }

    let decoder = image::codecs::bmp::BmpDecoder::new(Cursor::new(bytes))
        .map_err(|error| error.to_string())?;
    let (width, height) = decoder.dimensions();
    validate_image_dimensions(width, height)?;
    let rgba = image::DynamicImage::from_decoder(decoder)
        .map_err(|error| error.to_string())?
        .to_rgba8();
    debug_assert_eq!(rgba.dimensions(), (width, height));
    let mut png = Vec::new();
    image::codecs::png::PngEncoder::new(&mut png)
        .write_image(&rgba, width, height, image::ExtendedColorType::Rgba8)
        .map_err(|error| error.to_string())?;
    if png.len() as u64 > consts::MAX_IMAGE_FILE_SIZE {
        return Err(format!("normalized PNG is {} bytes", png.len()));
    }
    Ok(NormalizedImage { png, width, height })
}

fn validate_image_dimensions(width: u32, height: u32) -> Result<(), String> {
    let decoded_bytes = usize::try_from(width)
        .ok()
        .and_then(|width| {
            usize::try_from(height)
                .ok()
                .and_then(|height| width.checked_mul(height))
        })
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or_else(|| "image dimensions overflow".to_string())?;
    if decoded_bytes > consts::MAX_IMAGE_SIZE {
        return Err(format!("decoded image is {decoded_bytes} bytes"));
    }
    Ok(())
}

fn file_preview(paths: &[String]) -> String {
    let names = paths
        .iter()
        .take(3)
        .map(|path| {
            Path::new(path)
                .file_name()
                .map_or_else(|| path.as_str(), |name| name.to_str().unwrap_or(path))
        })
        .collect::<Vec<_>>()
        .join(" · ");
    if paths.len() > 3 {
        format!("{names} 等 {} 个文件", paths.len())
    } else {
        names
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_uri_lists_round_trip_unicode_and_spaces() {
        let paths = vec!["/tmp/a file.txt".to_string(), "/tmp/中文.png".to_string()];
        let encoded = encode_uri_list(&paths).expect("paths should encode");
        let decoded =
            parse_file_offer("text/uri-list", encoded.as_bytes()).expect("URI list should decode");
        assert_eq!(decoded, paths);
    }

    #[test]
    fn file_uri_list_ignores_comments_and_remote_uris() {
        let decoded = parse_file_offer(
            "text/uri-list",
            b"# copied files\r\nhttps://example.com/a\r\nfile:///tmp/local.txt\r\n",
        )
        .expect("URI list should decode");
        assert_eq!(decoded, ["/tmp/local.txt"]);
    }

    #[test]
    fn image_dimensions_obey_decoded_size_limit() {
        assert!(validate_image_dimensions(100, 100).is_ok());
        assert!(validate_image_dimensions(u32::MAX, u32::MAX).is_err());
    }
}
