//! Clipboard + logging commands — 3 of the 11 `#[frb]` functions.

use crate::core::clipboard_engine;
use crate::core::log;
use crate::core::state;

/// Copy an existing history item to the OS clipboard (text / rich / image),
/// marking it self-written so the poll loop does not re-record it.
pub fn copy_to_clipboard(id: usize) -> Result<(), String> {
    let history = state::st().history.lock().clone();
    clipboard_engine::copy_item_to_clipboard(&history, id)
}

/// Forward a frontend log line into the shared `cliphist.log`. Truncated to a
/// UTF-8 char boundary so non-ASCII (e.g. Chinese) logs do not panic when
/// slicing by byte index.
pub fn fe_log(message: String) {
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

/// Simulate a Ctrl+V paste into the previously-focused window.
///
/// M7 stub: the real injection (Linux evdev uinput via the privileged helper,
/// Windows `rdev`, macOS unsupported) lands in M7. Returning an `Err` keeps the
/// Dart side honest — no silent success while the feature is unimplemented.
pub fn simulate_paste_cmd() -> Result<(), String> {
    Err("simulate_paste: 实现 M7（global-hotkey/rdev/evdev uinput）".into())
}
