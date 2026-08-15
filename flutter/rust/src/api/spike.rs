//! Spike API: proves the FRB round-trip + StreamSink event channel end-to-end.
//!
//! Validates spike criterion A:
//!  - `get_history` / `copy_to_clipboard` / `update_settings` round-trip from Dart
//!  - `stream_clipboard_changed` pushes an event every 500ms that Dart renders
//!
//! This is throwaway scaffold — the real engine (arboard polling, ammonia
//! sanitize, settings persistence) is ported from `src-tauri/src/` in M2.

use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;
use std::thread;
use std::time::Duration;

#[frb(init)]
pub fn init_app() {
    // Default utilities — required by FRB; keep.
    flutter_rust_bridge::setup_default_user_utils();
}

/// Round-trip: return a stub history list.
#[frb(sync)]
pub fn get_history() -> Vec<String> {
    vec!["alpha".into(), "beta".into(), "gamma".into()]
}

/// Round-trip: validate error path (empty id rejected).
pub fn copy_to_clipboard(id: String) -> Result<(), String> {
    if id.is_empty() {
        Err("copy_to_clipboard: empty id".into())
    } else {
        Ok(())
    }
}

/// Round-trip: echo the patch back so Dart can confirm it arrived intact.
pub fn update_settings(patch: String) -> String {
    format!("applied:{patch}")
}

/// Event stream: push `tick N` every 500ms. Dart subscribes and must see the
/// first event within 1s. This stands in for the real `clipboard-changed` stream.
pub fn stream_clipboard_changed(sink: StreamSink<String>) -> Result<(), String> {
    thread::spawn(move || {
        let mut n = 0u32;
        loop {
            thread::sleep(Duration::from_millis(500));
            n += 1;
            if sink.add(format!("tick {n}")).is_err() {
                // Dart side dropped the sink — stop pushing.
                break;
            }
        }
    });
    Ok(())
}
