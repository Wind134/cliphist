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
#[flutter_rust_bridge::frb(sync)]
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

/// Simulate a Ctrl+V (Windows) / Cmd+V (macOS) / evdev-injected (Linux) paste
/// into the previously-focused window. Delegates to the platform paste engine
/// — Windows + macOS use `rdev::simulate`, Linux routes through the privileged
/// evdev helper. Returns `Err` on platforms without paste support or if the
/// synthetic event fails, so the Dart side surfaces it rather than a silent
/// no-op.
pub fn simulate_paste_cmd() -> Result<(), String> {
    crate::core::shortcut_engine::simulate_paste()
}
