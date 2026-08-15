use crate::core::clipboard_engine::ClipboardItem;
use crate::core::settings_store::Settings;
use parking_lot::Mutex;
use std::sync::mpsc;
use std::sync::{Arc, OnceLock};

/// Process-wide engine state. Owned once via [`STATE`] and reached through
/// [`st()`], replacing Tauri's managed `tauri::State`. Holding the fields
/// behind `Arc<Mutex<..>>` lets the background tasks share them with the
/// (later) Flutter-side commands without re-fetching the global.
pub struct AppState {
    pub history: Arc<Mutex<Vec<ClipboardItem>>>,
    pub counter: Arc<Mutex<usize>>,
    /// In-memory settings are the single source of truth. Keeping updates under
    /// one lock prevents resize events and UI patches from overwriting each
    /// other's freshly persisted fields.
    pub settings: Arc<Mutex<Settings>>,
    /// Sender for window-action requests (show/focus/raise). Triggers push `()`,
    /// and a single resident worker thread drains the channel and emits a
    /// `WindowActionKind` event for Dart to perform the actual OS dance (the
    /// Rust core holds no window handle). Avoids spawning a thread per trigger.
    pub window_action_tx: mpsc::Sender<()>,
}

static STATE: OnceLock<AppState> = OnceLock::new();

/// Install the global state. Called once from `init_app_state`.
pub fn set_state(state: AppState) {
    let _ = STATE.set(state);
}

/// Borrow the global state. Panics if `init_app_state` has not run yet — the
/// Dart side must `await initAppState()` before invoking any history/settings
/// command.
pub fn st() -> &'static AppState {
    STATE
        .get()
        .expect("AppState not initialized: call init_app_state first")
}

/// Internal: request the "pop to top" window-action dance. Feeds the resident
/// worker, which emits a `WindowActionKind::ShowAndRaise` event for Dart.
/// M3 wires hotkey / tray / double-tap triggers here.
pub fn request_window_action() {
    if let Some(s) = STATE.get() {
        let _ = s.window_action_tx.send(());
    }
}

/// Whether the privileged evdev double-tap helper is currently connected.
/// M8 wires this to the real Linux helper connection state; stubbed `false`
/// in M2 so the helper-status monitor thread exercises its emit path.
pub fn is_helper_connected() -> bool {
    false
}
