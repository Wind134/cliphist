use arboard::Clipboard;
use serde::{Deserialize, Serialize};
use std::io::Cursor;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClipboardItem {
    pub id: usize,
    pub content: String,
    pub content_type: String,
    pub timestamp: String,
    pub preview: String,
    pub char_count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_data: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_height: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub html_content: Option<String>,
}

pub fn get_storage_path() -> std::path::PathBuf {
    let data_dir = dirs::data_local_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("ClipHist");
    std::fs::create_dir_all(&data_dir).ok();
    data_dir.join("history.json")
}

pub fn save_history(items: &[ClipboardItem]) {
    if let Ok(json) = serde_json::to_string_pretty(items) {
        let path = get_storage_path();
        let _ = std::fs::write(path, json);
    }
}

pub fn load_history() -> Vec<ClipboardItem> {
    crate::log::write_log("load_history: start");
    let path = get_storage_path();
    crate::log::write_log(&format!("load_history: path={:?}", path));
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

pub fn copy_item_to_clipboard(history: &[ClipboardItem], id: usize) -> Result<(), String> {
    let item = history
        .iter()
        .find(|i| i.id == id)
        .ok_or("Item not found")?;

    let mut clipboard = Clipboard::new().map_err(|e| e.to_string())?;

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

    if let Some(ref html) = item.html_content {
        let _ = clipboard.set().html(html, Some(&item.content));
        return Ok(());
    }

    clipboard
        .set_text(&item.content)
        .map_err(|e| e.to_string())?;
    Ok(())
}
