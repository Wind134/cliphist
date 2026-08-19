//! Rust → Dart event streams. Dart subscribes to these `StreamSink`
//! registrations and receives events pushed from background tasks / commands via
//! `core::events::emit_*`. Each registration simply stashes the sink; the
//! matching emit helper no-ops when nothing is subscribed, so a headless test
//! run never blocks.

use crate::core::clipboard_engine::ClipboardItem;
use crate::core::events::{self, WindowActionKind};
use crate::frb_generated::StreamSink;

/// Top-5 clipboard snapshot after a new entry is recorded.
pub fn stream_clipboard_changed(sink: StreamSink<Vec<ClipboardItem>>) -> Result<(), String> {
    events::register_clipboard_changed(sink);
    Ok(())
}

/// Full history snapshot, pushed when items are removed anywhere in the list
/// (retention sweep).
pub fn stream_history_replace(sink: StreamSink<Vec<ClipboardItem>>) -> Result<(), String> {
    events::register_history_replace(sink);
    Ok(())
}

/// The id of the item just floated to the front by `move_to_top`.
pub fn stream_item_moved_to_top(sink: StreamSink<usize>) -> Result<(), String> {
    events::register_item_moved_to_top(sink);
    Ok(())
}

/// Whether the privileged evdev double-tap helper is authorized/connected.
pub fn stream_helper_status(sink: StreamSink<bool>) -> Result<(), String> {
    events::register_helper_status(sink);
    Ok(())
}

/// Window-action request (the Rust core owns no window handle). Dart performs
/// the always-on-top restack dance on receipt.
pub fn stream_window_action(sink: StreamSink<WindowActionKind>) -> Result<(), String> {
    events::register_window_action(sink);
    Ok(())
}

/// Reliable UI-isolate hand-off for native hotkey/double-tap/single-instance
/// wake requests. The stream above remains for compatibility, while the Dart
/// controller uses this synchronous coalescing poll on desktop platforms.
#[flutter_rust_bridge::frb(sync)]
pub fn take_pending_window_action() -> bool {
    crate::core::state::take_pending_window_action()
}
