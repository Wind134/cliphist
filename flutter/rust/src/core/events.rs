//! Rust → Dart event plumbing.
//!
//! Each cross-language event uses a `StreamSink<T>`. The api-side `stream_*`
//! functions register a sink when Dart subscribes; background tasks and
//! commands call the `emit_*` helpers to push events. A sink living in a
//! `parking_lot::Mutex<Option<..>>` is safe because FRB's `StreamSink` is
//! `Send`; the emit path no-ops when Dart has not subscribed, so a headless
//! `cargo test` never blocks.

use crate::core::clipboard_engine::ClipboardItem;
use crate::frb_generated::StreamSink;
use parking_lot::Mutex;

static CLIPBOARD_CHANGED_SINK: Mutex<Option<StreamSink<Vec<ClipboardItem>>>> = Mutex::new(None);
static HISTORY_REPLACE_SINK: Mutex<Option<StreamSink<Vec<ClipboardItem>>>> = Mutex::new(None);
static ITEM_MOVED_TO_TOP_SINK: Mutex<Option<StreamSink<usize>>> = Mutex::new(None);
static HELPER_STATUS_SINK: Mutex<Option<StreamSink<bool>>> = Mutex::new(None);

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

/// Whether the platform double-tap listener is currently available. On Linux
/// this is the privileged evdev helper connection.
pub(crate) fn emit_helper_status(connected: bool) {
    if let Some(sink) = HELPER_STATUS_SINK.lock().as_ref() {
        let _ = sink.add(connected);
    }
}
