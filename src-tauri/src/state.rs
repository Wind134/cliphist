use std::sync::Arc;
use std::sync::mpsc;
use parking_lot::Mutex;
use crate::clipboard::ClipboardItem;

pub struct AppState {
    pub history: Arc<Mutex<Vec<ClipboardItem>>>,
    pub counter: Arc<Mutex<usize>>,
    /// Sender for window-action requests (show/focus/raise). The double-tap
    /// listener and other triggers push `()`, and a single resident
    /// worker thread drains the channel and performs the (slightly heavy)
    /// window operations. Avoids spawning a thread per trigger.
    pub window_action_tx: mpsc::Sender<()>,
}

/// Shared double-tap state for the platform-specific listeners.
#[derive(Default)]
pub struct DoubleTapState {
    pub last_press: Option<std::time::Instant>,
    /// Whether the key has been released since the last press.
    /// This prevents key-repeat (long-press) from being treated as a double-tap.
    pub released: bool,
}
