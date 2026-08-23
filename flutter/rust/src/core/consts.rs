pub const MAX_HISTORY: usize = 500;
// Clipboard libraries expose decoded RGBA bytes, not the compressed PNG size.
// 64 MiB admits a 4K screenshot (~32 MiB) while still rejecting pathological
// clipboard payloads before another full-size allocation is made.
pub const MAX_IMAGE_SIZE: usize = 64 * 1024 * 1024;
pub const MAX_IMAGE_FILE_SIZE: u64 = 32 * 1024 * 1024;
pub const MAX_TEXT_SIZE: usize = 2 * 1024 * 1024; // 2 MiB UTF-8
pub const MAX_HTML_SIZE: usize = 4 * 1024 * 1024; // 4 MiB UTF-8
pub const MAX_FILE_LIST_SIZE: usize = 2 * 1024 * 1024; // encoded text/uri-list
pub const MAX_FILE_COUNT: usize = 4096;
pub const MAX_PREVIEW_CHARS: usize = 240;
pub const MAX_HISTORY_PAYLOAD_SIZE: usize = 16 * 1024 * 1024; // excludes image files
pub const MAX_HISTORY_FILE_SIZE: u64 = 24 * 1024 * 1024;
pub const MIN_ZOOM_LEVEL: f32 = 0.5;
pub const MAX_ZOOM_LEVEL: f32 = 2.0;
