use crate::core::clipboard_engine::ClipboardItem;
use crate::core::settings_store::Settings;
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, OnceLock};

/// Process-wide engine state. Owned once via [`STATE`] and reached through
/// [`st()`]. Holding the fields behind `Arc<Mutex<..>>` lets the background
/// tasks share them with Flutter-side commands without re-fetching the global.
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
static WINDOW_ACTION_PENDING: AtomicBool = AtomicBool::new(false);

/// Install the global state. Called once from `init_app_state`.
pub fn set_state(state: AppState) -> bool {
    STATE.set(state).is_ok()
}

pub fn is_initialized() -> bool {
    STATE.get().is_some()
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
pub fn request_window_action() {
    // A permanent FRB StreamSink proved unreliable for window wake events on
    // Windows: the native hook detected the double-tap, but Dart sometimes
    // never received the stream item. Keep a coalescing atomic flag as the
    // authoritative hand-off; Dart polls and clears it on its UI isolate.
    WINDOW_ACTION_PENDING.store(true, Ordering::SeqCst);
    if let Some(s) = STATE.get() {
        if s.window_action_tx.send(()).is_err() {
            crate::core::log::write_log("window action worker is unavailable");
        }
    }
}

/// Atomically consume a pending request to show/focus the window. Multiple
/// triggers before Dart's next poll intentionally coalesce into one dance.
pub fn take_pending_window_action() -> bool {
    WINDOW_ACTION_PENDING.swap(false, Ordering::SeqCst)
}

/// Whether the double-tap listener is currently authorized/connected. Backed
/// by the shortcut engine's listener flag: Windows/macOS set it when the
/// `rdev::grab` listener starts (and clear it on stop/error), Linux sets it
/// when the privileged evdev helper connects.
pub fn is_helper_connected() -> bool {
    crate::core::shortcut_engine::helper_connected()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_window_action_is_consumed_and_coalesced() {
        WINDOW_ACTION_PENDING.store(false, Ordering::SeqCst);
        assert!(!take_pending_window_action());

        request_window_action();
        request_window_action();
        assert!(take_pending_window_action());
        assert!(!take_pending_window_action());
    }
}
