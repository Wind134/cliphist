use arboard::Clipboard;
use serde::{Deserialize, Serialize};
use std::io::Cursor;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClipboardItem {
    pub id: usize,
    pub content: String,
    pub content_type: String,
    pub timestamp: String,
    pub preview: String,
    pub char_count: usize,
    /// Path (relative to the ClipHist data dir) of the external PNG file.
    /// Replaces the old inline base64 `image_data` so the JSON stays small
    /// and images are loaded on demand. `None` for non-image items.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_height: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub html_content: Option<String>,
}

static DATA_DIR: OnceLock<PathBuf> = OnceLock::new();
static IMAGES_DIR: OnceLock<PathBuf> = OnceLock::new();

/// Root ClipHist data dir (e.g. ~/.local/share/ClipHist).
/// Cached via `OnceLock` so `create_dir_all` runs only once.
pub fn data_dir() -> &'static PathBuf {
    DATA_DIR.get_or_init(|| {
        let dir = dirs::data_local_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("ClipHist");
        std::fs::create_dir_all(&dir).ok();
        dir
    })
}

/// Subdir where clipboard images are stored as `<id>.png`.
/// Cached via `OnceLock` so `create_dir_all` runs only once.
pub fn images_dir() -> &'static PathBuf {
    IMAGES_DIR.get_or_init(|| {
        let dir = data_dir().join("images");
        std::fs::create_dir_all(&dir).ok();
        dir
    })
}

pub fn get_storage_path() -> PathBuf {
    data_dir().join("history.json")
}

/// Write a clipboard image to `<images_dir>/<id>.png` and return its
/// storage-relative path (`images/<id>.png`) for serialization in the JSON.
/// Returns `None` if the file could not be written.
///
/// Atomic: write to a temp sibling then rename, so a crash mid-write cannot
/// leave a half-decoded PNG that the frontend would later fail to load.
pub fn save_image_file(id: usize, png: &[u8]) -> Option<String> {
    let abs = images_dir().join(format!("{}.png", id));
    let tmp = images_dir().join(format!("{}.png.tmp", id));
    let wrote = if std::fs::write(&tmp, png).is_ok() && std::fs::rename(&tmp, &abs).is_ok() {
        true
    } else {
        // Fallback: direct write if the temp+rename path failed.
        let _ = std::fs::remove_file(&tmp);
        std::fs::write(&abs, png).is_ok()
    };
    if wrote {
        Some(format!("images/{}.png", id))
    } else {
        crate::core::log::write_log(&format!("Failed to write image file {:?}", abs));
        None
    }
}

/// Read an image file by its storage-relative path (`images/<id>.png`).
pub fn read_image_file(rel: &str) -> Option<Vec<u8>> {
    let safe_rel = safe_image_path(rel)?;
    let abs = data_dir().join(safe_rel);
    std::fs::read(abs).ok()
}

fn safe_image_path(rel: &str) -> Option<&std::path::Path> {
    let path = std::path::Path::new(rel);
    let mut components = path.components();
    match (components.next(), components.next(), components.next()) {
        (
            Some(std::path::Component::Normal(dir)),
            Some(std::path::Component::Normal(file)),
            None,
        ) if dir == "images" && file.to_string_lossy().ends_with(".png") => Some(path),
        _ => None,
    }
}

/// Best-effort removal of an image file referenced by `path`.
pub fn delete_image_file(path: &Option<String>) {
    if let Some(rel) = path {
        let Some(safe_rel) = safe_image_path(rel) else {
            return;
        };
        let abs = data_dir().join(safe_rel);
        let _ = std::fs::remove_file(abs);
    }
}

/// Atomically persist history: write a temp file, then rename over the
/// target. Avoids leaving a half-written JSON if the process is interrupted
/// mid-write. The payload is now small (images are external), so this is cheap.
pub fn save_history(items: &[ClipboardItem]) {
    if let Ok(json) = serde_json::to_string_pretty(items) {
        let path = get_storage_path();
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, &json).is_ok() && std::fs::rename(&tmp, &path).is_ok() {
            return;
        }
        // Fallback: write directly if the temp+rename path failed.
        let _ = std::fs::write(&path, &json);
        let _ = std::fs::remove_file(&tmp);
    }
}

pub fn load_history() -> Vec<ClipboardItem> {
    crate::core::log::write_log("load_history: start");
    let path = get_storage_path();
    crate::core::log::write_log(&format!("load_history: path={:?}", path));
    if let Ok(json) = std::fs::read_to_string(path) {
        if let Ok(items) = serde_json::from_str::<Vec<ClipboardItem>>(&json) {
            return items;
        }
    }
    Vec::new()
}

pub fn make_preview(content: &str) -> String {
    let trimmed = content.trim();
    if trimmed.char_indices().count() <= 80 {
        trimmed.to_string()
    } else {
        let preview: String = trimmed.chars().take(80).collect();
        format!("{}...", preview)
    }
}

pub fn get_content_type(content: &str) -> String {
    let t = content.trim();
    // A link is a single bare token that starts with a scheme or "www."
    // (no embedded spaces). The old `contains("www.")` check misclassified any
    // text merely mentioning "www." as a link.
    let is_link = t.starts_with("http://")
        || t.starts_with("https://")
        || (t.starts_with("www.") && t.contains('.') && !t.contains(' '));
    if is_link {
        "link".to_string()
    } else if t.chars().count() > 50 {
        "text".to_string()
    } else {
        "short".to_string()
    }
}

pub fn parse_timestamp(ts: &str) -> Option<chrono::NaiveDateTime> {
    use chrono::NaiveDateTime;
    // 先尝试完整格式
    if let Ok(dt) = NaiveDateTime::parse_from_str(ts, "%Y-%m-%d %H:%M:%S") {
        return Some(dt);
    }
    // 再尝试旧格式（视为今天）
    if let Ok(time) = chrono::NaiveTime::parse_from_str(ts, "%H:%M:%S") {
        let today = chrono::Local::now().date_naive();
        return Some(today.and_time(time));
    }
    None
}

// ── Self-write tracking ──────────────────────────────────────────────────────
//
// When the user copies an item *from this manager*, we write to the OS
// clipboard. The poll loop would otherwise read that content back and record
// it as a brand-new history entry — duplicating the item. To prevent that,
// `copy_item_to_clipboard` stores the hash of whatever it just wrote here,
// and the poll loop consumes the marker: if the polled content's hash matches,
// the poll updates its "last seen" hash and skips the insert.

static LAST_SELF_SET_HASH: AtomicU64 = AtomicU64::new(0);

/// Stable hash over a text payload. Must match the hash used by the poll loop
/// so a self-write marker is recognized.
pub fn simple_hash(s: &str) -> u64 {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    s.hash(&mut h);
    h.finish()
}

/// Stable hash over an `arboard` image payload. Must match the hash used by
/// the poll loop.
pub fn img_hash(img: &arboard::ImageData) -> u64 {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    img.bytes.hash(&mut h);
    h.finish()
}

/// Record the hash of content we just wrote to the OS clipboard, so the poll
/// loop can recognize and skip re-recording it.
pub fn mark_self_set(hash: u64) {
    LAST_SELF_SET_HASH.store(hash, Ordering::SeqCst);
}

/// Atomically read and clear the pending self-write marker. Returns 0 if none
/// is pending. The marker is consumed even on mismatch (it is then stale).
pub fn take_self_set_hash() -> u64 {
    LAST_SELF_SET_HASH.swap(0, Ordering::SeqCst)
}

pub fn copy_item_to_clipboard(history: &[ClipboardItem], id: usize) -> Result<(), String> {
    let item = history
        .iter()
        .find(|i| i.id == id)
        .ok_or("Item not found")?;

    let mut clipboard = Clipboard::new().map_err(|e| e.to_string())?;

    // Images are stored as external PNG files; load on demand.
    if let Some(ref rel) = item.image_path {
        if let Some(img_bytes) = read_image_file(rel) {
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
            // Mark this exact image as self-written so the poll loop doesn't
            // re-record it as a new history entry.
            mark_self_set(img_hash(&img_data));
            clipboard.set_image(img_data).map_err(|e| e.to_string())?;
            return Ok(());
        }
    }

    if let Some(ref html) = item.html_content {
        clipboard
            .set()
            .html(html, Some(&item.content))
            .map_err(|e| e.to_string())?;
        // The poll loop reads back the plain-text alt (`item.content`), so mark
        // that hash to suppress the duplicate.
        mark_self_set(simple_hash(&item.content));
        return Ok(());
    }

    clipboard
        .set_text(&item.content)
        .map_err(|e| e.to_string())?;
    // Suppress the poll loop re-recording what we just wrote.
    mark_self_set(simple_hash(&item.content));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_uses_unicode_characters_and_truncates() {
        assert_eq!(make_preview("  你好  "), "你好");
        let long = "界".repeat(81);
        let preview = make_preview(&long);
        assert_eq!(preview.chars().count(), 83);
        assert!(preview.ends_with("..."));
    }

    #[test]
    fn content_type_only_marks_bare_urls_as_links() {
        assert_eq!(get_content_type("https://example.com/a"), "link");
        assert_eq!(get_content_type("see https://example.com"), "short");
        assert_eq!(get_content_type("www.example.com"), "link");
    }

    #[test]
    fn image_paths_cannot_escape_storage() {
        assert_eq!(
            safe_image_path("images/42.png"),
            Some(std::path::Path::new("images/42.png"))
        );
        assert_eq!(safe_image_path("../settings.json"), None);
        assert_eq!(safe_image_path("images/../settings.json"), None);
        assert_eq!(safe_image_path("/tmp/a.png"), None);
        assert_eq!(safe_image_path("other/a.png"), None);
    }

    #[test]
    fn parses_current_timestamp_format() {
        assert!(parse_timestamp("2026-07-25 12:34:56").is_some());
        assert!(parse_timestamp("not a timestamp").is_none());
    }
}
