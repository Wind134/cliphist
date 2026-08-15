//! Rust → Dart event plumbing.
//!
//! Each Tauri `app.emit(event, payload)` from the old stack becomes a
//! `StreamSink<T>` here. The api-side `stream_*` functions register a sink
//! (called from Dart when it subscribes); the background tasks and commands
//! call the `emit_*` helpers to push events. A sink living in a `parking_lot`
//! `Mutex<Option<..>>` is fine because FRB's `StreamSink` is `Send` (the spike
//! moved one into a spawned thread); the emit path no-ops when no Dart side is
//! subscribed, so a headless `cargo test` never blocks.

use crate::core::clipboard_engine::ClipboardItem;
use crate::frb_generated::StreamSink;
use parking_lot::Mutex;

/// A window-action request pushed to Dart. The Rust core owns no window
/// handle (decision 3.2), so the actual always-on-top restack dance runs in
/// Dart via `window_manager` — this enum is the trigger.
#[derive(Clone)]
pub enum WindowActionKind {
    /// Pin on top, hide, show + focus, then release always-on-top. The full
    /// dance sequence is implemented in the Dart listener (M3).
    ShowAndRaise,
}

static CLIPBOARD_CHANGED_SINK: Mutex<Option<StreamSink<Vec<ClipboardItem>>>> = Mutex::new(None);
static HISTORY_REPLACE_SINK: Mutex<Option<StreamSink<Vec<ClipboardItem>>>> = Mutex::new(None);
static ITEM_MOVED_TO_TOP_SINK: Mutex<Option<StreamSink<usize>>> = Mutex::new(None);
static HELPER_STATUS_SINK: Mutex<Option<StreamSink<bool>>> = Mutex::new(None);
static WINDOW_ACTION_SINK: Mutex<Option<StreamSink<WindowActionKind>>> = Mutex::new(None);

pub(crate) fn register_clipboard_changed(sink: StreamSink<Vec<ClipboardItem>>) {
    *CLIPBOARD_CHANGED_SINK.lock() = Some(sink);
}
pub(crate) fn register_history_replace(sink: StreamSink<Vec<ClipboardItem>>) {
    *HISTORY_REPLACE_SINK.lock() = Some(sink);
}
pub(crate) fn register_item_moved_to_top(sink: StreamSink<usize>) {
    *ITEM_MOVED_TO_TOP_SINK.lock() = Some(sink);
}
pub(crate) fn register_helper_status(sink: StreamSink<bool>) {
    *HELPER_STATUS_SINK.lock() = Some(sink);
}
pub(crate) fn register_window_action(sink: StreamSink<WindowActionKind>) {
    *WINDOW_ACTION_SINK.lock() = Some(sink);
}

/// Top-5 snapshot after a new item is recorded (incremental update).
pub(crate) fn emit_clipboard_changed(items: Vec<ClipboardItem>) {
    if let Some(sink) = CLIPBOARD_CHANGED_SINK.lock().as_ref() {
        let _ = sink.add(items);
    }
}

/// Full history snapshot, used when items anywhere in the list are removed
/// (the top-5 stream cannot convey deletions beyond the head).
pub(crate) fn emit_history_replace(items: Vec<ClipboardItem>) {
    if let Some(sink) = HISTORY_REPLACE_SINK.lock().as_ref() {
        let _ = sink.add(items);
    }
}

/// The id of the item just floated to the front by `move_to_top`.
pub(crate) fn emit_item_moved_to_top(id: usize) {
    if let Some(sink) = ITEM_MOVED_TO_TOP_SINK.lock().as_ref() {
        let _ = sink.add(id);
    }
}

/// Whether the privileged evdev helper is currently authorized/connected
/// (Linux double-tap indicator).
pub(crate) fn emit_helper_status(connected: bool) {
    if let Some(sink) = HELPER_STATUS_SINK.lock().as_ref() {
        let _ = sink.add(connected);
    }
}

/// Request the window-action dance be performed on the Dart side.
pub(crate) fn emit_window_action(kind: WindowActionKind) {
    if let Some(sink) = WINDOW_ACTION_SINK.lock().as_ref() {
        let _ = sink.add(kind);
    }
}
