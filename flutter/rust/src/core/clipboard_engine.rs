#[cfg(not(target_os = "linux"))]
use arboard::Clipboard;
use serde::{Deserialize, Serialize};
#[cfg(not(target_os = "linux"))]
use std::io::Cursor;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

use crate::core::{consts, storage};

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
    /// File paths carried by a Wayland `text/uri-list` offer. This may coexist
    /// with text, HTML and image alternatives from the same clipboard event.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_paths: Option<Vec<String>>,
    /// Stable content identity used for whole-history deduplication. Optional
    /// on disk for migration from releases that predate this field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_hash: Option<String>,
}

static DATA_DIR: OnceLock<PathBuf> = OnceLock::new();
static IMAGES_DIR: OnceLock<PathBuf> = OnceLock::new();

/// Root My ClipHist data dir (e.g. ~/.local/share/my-cliphist).
/// Cached via `OnceLock` so `create_dir_all` runs only once.
pub fn data_dir() -> &'static PathBuf {
    DATA_DIR.get_or_init(|| {
        let dir = storage::app_data_dir();
        if let Err(error) = storage::ensure_private_dir(&dir) {
            crate::core::log::write_log(&error);
        }
        dir
    })
}

/// Subdir where clipboard images are stored as `<id>.png`.
/// Cached via `OnceLock` so `create_dir_all` runs only once.
pub fn images_dir() -> &'static PathBuf {
    IMAGES_DIR.get_or_init(|| {
        let dir = data_dir().join("images");
        if let Err(error) = storage::ensure_private_dir(&dir) {
            crate::core::log::write_log(&error);
        }
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
    if png.len() as u64 > consts::MAX_IMAGE_FILE_SIZE {
        crate::core::log::write_log(&format!(
            "Encoded image too large ({} bytes), skipping",
            png.len()
        ));
        return None;
    }
    match storage::atomic_write_without_backup(&abs, png) {
        Ok(()) => Some(format!("images/{id}.png")),
        Err(error) => {
            crate::core::log::write_log(&format!("Failed to write image file {abs:?}: {error}"));
            None
        }
    }
}

/// Read an image file by its storage-relative path (`images/<id>.png`).
pub fn read_image_file(rel: &str) -> Option<Vec<u8>> {
    let safe_rel = safe_image_path(rel)?;
    let abs = data_dir().join(safe_rel);
    let metadata = std::fs::metadata(&abs).ok()?;
    if !metadata.is_file() || metadata.len() > consts::MAX_IMAGE_FILE_SIZE {
        crate::core::log::write_log(&format!("Rejected invalid image file {abs:?}"));
        return None;
    }
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
pub fn save_history(items: &[ClipboardItem]) -> Result<(), String> {
    let json =
        serde_json::to_vec(items).map_err(|e| format!("Failed to serialize history: {}", e))?;
    if json.len() as u64 > consts::MAX_HISTORY_FILE_SIZE {
        return Err(format!(
            "History is too large to persist: {} bytes (limit {})",
            json.len(),
            consts::MAX_HISTORY_FILE_SIZE
        ));
    }
    let path = get_storage_path();
    storage::atomic_write(&path, &json)
}

pub fn load_history() -> Vec<ClipboardItem> {
    crate::core::log::write_log("load_history: start");
    let path = get_storage_path();
    crate::core::log::write_log(&format!("load_history: path={:?}", path));
    match storage::load_json_with_backup::<Vec<ClipboardItem>>(&path, consts::MAX_HISTORY_FILE_SIZE)
    {
        Ok(Some(mut items)) => {
            // Re-sanitize persisted rich text as a migration boundary. Older
            // versions may have stored HTML before the current allowlist was
            // introduced; rendering it must not revive remote images or old
            // unsafe attributes.
            let mut changed = false;
            for item in &mut items {
                if let Some(html) = item.html_content.take() {
                    let clean = crate::core::sanitize::sanitize_html(&html);
                    changed |= clean != html;
                    if clean.is_empty() {
                        item.content_type = get_content_type(&item.content);
                    } else {
                        item.html_content = Some(clean);
                    }
                } else if item.content_type == "rich" {
                    item.content_type = get_content_type(&item.content);
                    changed = true;
                }
                if item.content.len() > consts::MAX_TEXT_SIZE {
                    item.content
                        .truncate(floor_char_boundary(&item.content, consts::MAX_TEXT_SIZE));
                    item.preview = make_preview(&item.content);
                    item.char_count = item.content.chars().count();
                    changed = true;
                }
                if item
                    .html_content
                    .as_ref()
                    .is_some_and(|html| html.len() > consts::MAX_HTML_SIZE)
                {
                    item.html_content = None;
                    item.content_type = get_content_type(&item.content);
                    changed = true;
                }
                if let Some(paths) = item.file_paths.as_mut() {
                    let original_len = paths.len();
                    paths.retain(|path| !path.is_empty() && path.len() <= consts::MAX_TEXT_SIZE);
                    if paths.len() > consts::MAX_FILE_COUNT {
                        paths.truncate(consts::MAX_FILE_COUNT);
                    }
                    let mut total = 0usize;
                    paths.retain(|path| {
                        total = total.saturating_add(path.len());
                        total <= consts::MAX_FILE_LIST_SIZE
                    });
                    changed |= paths.len() != original_len;
                    if paths.is_empty() {
                        item.file_paths = None;
                        if item.content_type == "files" {
                            item.content_type = get_content_type(&item.content);
                        }
                        changed = true;
                    } else if item.content_type != "files" {
                        item.content_type = "files".to_string();
                        changed = true;
                    }
                } else if item.content_type == "files" {
                    item.content_type = get_content_type(&item.content);
                    changed = true;
                }
                let expected_hash = item_content_hash(item);
                if item.content_hash.as_ref() != Some(&expected_hash) {
                    item.content_hash = Some(expected_hash);
                    changed = true;
                }
            }
            let before_validation = items.len();
            items.retain(|item| {
                item.content_type != "image"
                    || item
                        .image_path
                        .as_deref()
                        .and_then(read_image_file)
                        .is_some()
            });
            changed |= items.len() != before_validation;

            // A fingerprint is only an index hint: always confirm the actual
            // payload before dropping an entry. This both protects against a
            // (very unlikely) hash collision and keeps migration semantics in
            // line with the live commit path.
            let before_deduplication = items.len();
            let (mut items, mut obsolete_images) = deduplicate_history(items);
            changed |= items.len() != before_deduplication;

            changed |= repair_history_ids(&mut items);
            obsolete_images.extend(trim_history(&mut items));
            changed |= !obsolete_images.is_empty();
            if changed {
                match save_history(&items) {
                    Ok(()) => {
                        for path in obsolete_images {
                            let still_referenced = path.as_ref().is_some_and(|path| {
                                items
                                    .iter()
                                    .any(|item| item.image_path.as_ref() == Some(path))
                            });
                            if !still_referenced {
                                delete_image_file(&path);
                            }
                        }
                    }
                    Err(e) => {
                        // Keep every old image until the corresponding new
                        // snapshot is durable. The sanitized in-memory view is
                        // still safe and a later mutation will retry saving it.
                        crate::core::log::write_log(&format!(
                            "Failed to persist sanitized history migration: {e}"
                        ));
                    }
                }
            }
            return items;
        }
        Ok(None) => {}
        Err(error) => crate::core::log::write_log(&format!(
            "Failed to load clipboard history from {path:?}: {error}"
        )),
    }
    Vec::new()
}

fn floor_char_boundary(value: &str, max_bytes: usize) -> usize {
    let mut index = value.len().min(max_bytes);
    while !value.is_char_boundary(index) {
        index -= 1;
    }
    index
}

pub fn content_hash(
    text: &str,
    html: Option<&str>,
    png: Option<&[u8]>,
    file_paths: Option<&[String]>,
) -> String {
    let path_bytes = file_paths.map_or(0, |paths| paths.iter().map(String::len).sum());
    let mut bytes = Vec::with_capacity(
        text.len() + html.map_or(0, str::len) + png.map_or(0, <[u8]>::len) + path_bytes + 40,
    );
    bytes.extend_from_slice(b"text\0");
    bytes.extend_from_slice(text.as_bytes());
    bytes.extend_from_slice(b"\0html\0");
    if let Some(html) = html {
        bytes.extend_from_slice(html.as_bytes());
    }
    bytes.extend_from_slice(b"\0image/png\0");
    if let Some(png) = png {
        bytes.extend_from_slice(png);
    }
    bytes.extend_from_slice(b"\0files\0");
    if let Some(paths) = file_paths {
        for path in paths {
            bytes.extend_from_slice(path.as_bytes());
            bytes.push(0);
        }
    }
    stable_content_hash(&bytes)
}

pub fn text_content_hash(text: &str, html: Option<&str>) -> String {
    content_hash(text, html, None, None)
}

pub fn image_content_hash(png: &[u8]) -> String {
    content_hash("", None, Some(png), None)
}

/// A deterministic 128-bit fingerprint composed from two independently
/// seeded FNV-1a passes. This is an identity hint for deduplication, not a
/// security boundary; comparing hashes avoids retaining a second full payload.
fn stable_content_hash(bytes: &[u8]) -> String {
    fn fnv1a(bytes: &[u8], mut state: u64) -> u64 {
        for byte in bytes {
            state ^= u64::from(*byte);
            state = state.wrapping_mul(0x0000_0100_0000_01b3);
        }
        state
    }

    let first = fnv1a(bytes, 0xcbf2_9ce4_8422_2325);
    let second = fnv1a(bytes, 0x8422_2325_cbf2_9ce4);
    format!("{first:016x}{second:016x}")
}

fn item_content_hash(item: &ClipboardItem) -> String {
    let image = item.image_path.as_deref().and_then(read_image_file);
    content_hash(
        &item.content,
        item.html_content.as_deref(),
        image.as_deref(),
        item.file_paths.as_deref(),
    )
}

fn payload_size(item: &ClipboardItem) -> usize {
    item.content.len()
        + item.preview.len()
        + item.html_content.as_ref().map_or(0, String::len)
        + item
            .file_paths
            .as_ref()
            .map_or(0, |paths| paths.iter().map(String::len).sum())
}

/// Enforce both count and aggregate inline-payload limits. Returns image paths
/// that may be removed only after the trimmed snapshot is durably persisted.
pub fn trim_history(items: &mut Vec<ClipboardItem>) -> Vec<Option<String>> {
    let mut total = items.iter().map(payload_size).sum::<usize>();
    let mut removed = Vec::new();
    while items.len() > consts::MAX_HISTORY || total > consts::MAX_HISTORY_PAYLOAD_SIZE {
        let Some(item) = items.pop() else {
            break;
        };
        total = total.saturating_sub(payload_size(&item));
        removed.push(item.image_path);
    }
    removed
}

/// Insert a new item, or refresh a matching older item, then persist before
/// exposing the mutation to readers. Returns obsolete image paths after the
/// commit succeeds.
pub fn commit_item(
    history: &mut Vec<ClipboardItem>,
    mut item: ClipboardItem,
) -> Result<Vec<Option<String>>, String> {
    let mut next = history.clone();
    let mut removed_images = Vec::new();
    if let Some(hash) = item.content_hash.as_ref() {
        if let Some(position) = next.iter().position(|existing| {
            existing.content_hash.as_ref() == Some(hash) && same_content(existing, &item)
        }) {
            let mut existing = next.remove(position);
            // A capture may already have externalized a replacement image.
            // Keep the established item/file and remove the unreferenced new
            // file only after the reordered snapshot commits successfully.
            removed_images.push(item.image_path.take());
            existing.timestamp = item.timestamp;
            existing.preview = item.preview;
            existing.char_count = item.char_count;
            item = existing;
        }
    }
    next.insert(0, item);
    removed_images.extend(trim_history(&mut next));
    save_history(&next)?;
    *history = next;
    Ok(removed_images)
}

fn same_content(left: &ClipboardItem, right: &ClipboardItem) -> bool {
    let images_match = match (left.image_path.as_deref(), right.image_path.as_deref()) {
        (None, None) => true,
        (Some(left), Some(right)) => read_image_file(left)
            .zip(read_image_file(right))
            .is_some_and(|(left, right)| left == right),
        _ => false,
    };
    images_match
        && left.content == right.content
        && left.html_content == right.html_content
        && left.file_paths == right.file_paths
}

fn deduplicate_history(items: Vec<ClipboardItem>) -> (Vec<ClipboardItem>, Vec<Option<String>>) {
    let mut deduplicated = Vec::with_capacity(items.len());
    let mut obsolete_images = Vec::new();
    for item in items {
        let is_duplicate = item.content_hash.as_ref().is_some_and(|hash| {
            deduplicated.iter().any(|existing: &ClipboardItem| {
                existing.content_hash.as_ref() == Some(hash) && same_content(existing, &item)
            })
        });
        if is_duplicate {
            obsolete_images.push(item.image_path);
        } else {
            deduplicated.push(item);
        }
    }
    (deduplicated, obsolete_images)
}

/// IDs are process-local record handles, not external identifiers. Repair a
/// crafted/obsolete snapshot as a group when IDs are duplicated, zero, or so
/// large that the monotonic capture counter is no longer operationally safe.
fn repair_history_ids(items: &mut [ClipboardItem]) -> bool {
    const MAX_REASONABLE_ITEM_ID: usize = 1_000_000_000_000;

    let mut seen = std::collections::HashSet::with_capacity(items.len());
    let needs_repair = items
        .iter()
        .any(|item| item.id == 0 || item.id > MAX_REASONABLE_ITEM_ID || !seen.insert(item.id));
    if !needs_repair {
        return false;
    }

    let count = items.len();
    for (index, item) in items.iter_mut().enumerate() {
        // Newest-first history receives descending IDs, leaving `count` as
        // the next counter base while preserving the existing list order.
        item.id = count - index;
    }
    true
}

pub fn make_preview(content: &str) -> String {
    let trimmed = content.trim();
    if trimmed.chars().count() <= consts::MAX_PREVIEW_CHARS {
        trimmed.to_string()
    } else {
        let preview: String = trimmed.chars().take(consts::MAX_PREVIEW_CHARS).collect();
        format!("{}...", preview)
    }
}

pub fn get_content_type(content: &str) -> String {
    let t = content.trim();
    // A link is a single bare token that starts with a scheme or "www."
    // (no embedded spaces). The old `contains("www.")` check misclassified any
    // text merely mentioning "www." as a link.
    let is_link = !t.chars().any(char::is_whitespace)
        && (t.starts_with("http://")
            || t.starts_with("https://")
            || (t.starts_with("www.") && t.contains('.')));
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
#[cfg(not(target_os = "linux"))]
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

#[cfg(not(target_os = "linux"))]
pub fn copy_item_to_clipboard(history: &[ClipboardItem], id: usize) -> Result<(), String> {
    let item = history
        .iter()
        .find(|i| i.id == id)
        .ok_or("Item not found")?;

    let mut clipboard = Clipboard::new().map_err(|e| e.to_string())?;

    // Images are stored as external PNG files; load on demand.
    if let Some(ref rel) = item.image_path {
        let img_bytes =
            read_image_file(rel).ok_or_else(|| format!("图片文件缺失或无效，无法复制: {rel}"))?;
        let decoder = image::codecs::png::PngDecoder::new(Cursor::new(&img_bytes))
            .map_err(|e| format!("图片解码失败: {e}"))?;
        let img: image::DynamicImage =
            image::DynamicImage::from_decoder(decoder).map_err(|e| format!("图片解码失败: {e}"))?;
        let rgba = img.to_rgba8();
        let (w, h) = rgba.dimensions();
        let img_data = arboard::ImageData {
            width: w as usize,
            height: h as usize,
            bytes: rgba.into_raw().into(),
        };
        // Mark this exact image as self-written so the poll loop doesn't
        // re-record it as a new history entry.
        let self_hash = img_hash(&img_data);
        clipboard.set_image(img_data).map_err(|e| e.to_string())?;
        mark_self_set(self_hash);
        return Ok(());
    }
    if item.content_type == "image" {
        return Err("图片记录没有可用的图片文件".to_string());
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

#[cfg(target_os = "linux")]
pub fn copy_item_to_clipboard(history: &[ClipboardItem], id: usize) -> Result<(), String> {
    use wl_clipboard_rs::copy::{MimeSource, MimeType, Options, Source};

    let item = history
        .iter()
        .find(|item| item.id == id)
        .ok_or("Item not found")?;
    let mut sources = Vec::new();

    // New Wayland image records leave `content` empty. Do not expose the
    // synthetic preview text stored by older releases as a text alternative.
    let has_real_text = !item.content.is_empty()
        && (item.content_type != "image"
            || item.html_content.is_some()
            || item.file_paths.is_some());
    if has_real_text {
        sources.push(MimeSource {
            source: Source::Bytes(item.content.clone().into_bytes().into_boxed_slice()),
            mime_type: MimeType::Text,
        });
    }

    if let Some(html) = item.html_content.as_ref() {
        sources.push(MimeSource {
            source: Source::Bytes(html.clone().into_bytes().into_boxed_slice()),
            mime_type: MimeType::Specific("text/html".to_string()),
        });
    }

    if let Some(path) = item.image_path.as_deref() {
        let png =
            read_image_file(path).ok_or_else(|| format!("图片文件缺失或无效，无法复制: {path}"))?;
        sources.push(MimeSource {
            source: Source::Bytes(png.into_boxed_slice()),
            mime_type: MimeType::Specific("image/png".to_string()),
        });
    } else if item.content_type == "image" {
        return Err("图片记录没有可用的图片文件".to_string());
    }

    if let Some(paths) = item.file_paths.as_deref() {
        let uri_list = crate::core::wayland_clipboard::encode_uri_list(paths)?;
        sources.push(MimeSource {
            source: Source::Bytes(uri_list.clone().into_bytes().into_boxed_slice()),
            mime_type: MimeType::Specific("text/uri-list".to_string()),
        });
        sources.push(MimeSource {
            source: Source::Bytes(b"0".to_vec().into_boxed_slice()),
            mime_type: MimeType::Specific("application/x-kde-cutselection".to_string()),
        });
        sources.push(MimeSource {
            source: Source::Bytes(
                format!("copy\n{}", uri_list.replace("\r\n", "\n"))
                    .into_bytes()
                    .into_boxed_slice(),
            ),
            mime_type: MimeType::Specific("x-special/gnome-copied-files".to_string()),
        });
    }

    if sources.is_empty() {
        return Err("该记录没有可复制的剪贴板内容".to_string());
    }

    // Mark before publishing: the watcher runs concurrently and may observe
    // the Wayland selection as soon as the compositor accepts it.
    let self_hash = simple_hash(&item_content_hash(item));
    mark_self_set(self_hash);
    let mut options = Options::new();
    // If an HTML-only record has no genuine plain-text alternative, do not
    // let wl-clipboard-rs synthesize text/plain from the HTML markup.
    options.omit_additional_text_mime_types(!has_real_text);
    if let Err(error) = options.copy_multi(sources) {
        take_self_set_hash();
        return Err(format!("写入 Wayland 剪贴板失败: {error}"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text_item(id: usize, content: String) -> ClipboardItem {
        ClipboardItem {
            id,
            content_hash: Some(text_content_hash(&content, None)),
            preview: make_preview(&content),
            char_count: content.chars().count(),
            content,
            content_type: "text".to_string(),
            timestamp: "2026-08-19 12:00:00".to_string(),
            image_path: None,
            image_width: None,
            image_height: None,
            html_content: None,
            file_paths: None,
        }
    }

    #[test]
    fn preview_uses_unicode_characters_and_truncates() {
        assert_eq!(make_preview("  你好  "), "你好");
        let long = "界".repeat(consts::MAX_PREVIEW_CHARS + 1);
        let preview = make_preview(&long);
        assert_eq!(preview.chars().count(), consts::MAX_PREVIEW_CHARS + 3);
        assert!(preview.ends_with("..."));
    }

    #[test]
    fn content_type_only_marks_bare_urls_as_links() {
        assert_eq!(get_content_type("https://example.com/a"), "link");
        assert_eq!(get_content_type("see https://example.com"), "short");
        assert_eq!(get_content_type("https://example.com/a b"), "short");
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

    #[test]
    fn content_fingerprints_are_deterministic_and_representation_aware() {
        assert_eq!(
            text_content_hash("hello", Some("<b>hello</b>")),
            text_content_hash("hello", Some("<b>hello</b>"))
        );
        assert_ne!(
            text_content_hash("hello", None),
            text_content_hash("hello", Some("<b>hello</b>"))
        );
        assert_ne!(
            image_content_hash(b"hello"),
            text_content_hash("hello", None)
        );
    }

    #[test]
    fn trim_history_enforces_aggregate_payload_limit() {
        let chunk = "x".repeat(consts::MAX_TEXT_SIZE);
        let mut items = (0..20)
            .map(|id| text_item(id, chunk.clone()))
            .collect::<Vec<_>>();
        let removed = trim_history(&mut items);
        let remaining_size = items.iter().map(payload_size).sum::<usize>();
        assert!(!removed.is_empty());
        assert!(remaining_size <= consts::MAX_HISTORY_PAYLOAD_SIZE);
    }

    #[test]
    fn deduplication_confirms_content_instead_of_trusting_hashes() {
        let first = text_item(1, "first".to_string());
        let mut collision = text_item(2, "second".to_string());
        collision.content_hash.clone_from(&first.content_hash);
        let mut duplicate = first.clone();
        duplicate.id = 3;

        let (deduplicated, removed_images) = deduplicate_history(vec![first, collision, duplicate]);

        assert_eq!(deduplicated.len(), 2);
        assert_eq!(deduplicated[0].content, "first");
        assert_eq!(deduplicated[1].content, "second");
        assert_eq!(removed_images, vec![None]);
    }

    #[test]
    fn invalid_or_duplicate_ids_are_repaired_as_one_consistent_sequence() {
        let mut items = vec![
            text_item(usize::MAX, "first".to_string()),
            text_item(7, "second".to_string()),
            text_item(7, "third".to_string()),
        ];

        assert!(repair_history_ids(&mut items));
        assert_eq!(
            items.iter().map(|item| item.id).collect::<Vec<_>>(),
            [3, 2, 1]
        );
        assert!(!repair_history_ids(&mut items));
    }
}
