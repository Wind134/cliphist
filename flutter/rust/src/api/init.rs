//! One-time engine initialization. Dart calls `await initAppState()` after
//! `RustLib.init()` and before any history/settings command.

use crate::core::clipboard_engine;
use crate::core::log;
use crate::core::settings_store;
use crate::core::state::{self, AppState};
use parking_lot::Mutex;
use std::sync::mpsc;
use std::sync::Arc;

/// FRB init hook — invoked by `RustLib.init()` on the Dart side before any
/// other `#[frb]` call. Sets up the default user utils.
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Outcome of the single-instance check, surfaced to Dart before it decides
/// whether to run the app or exit.
pub struct SingleInstanceResult {
    /// `true` if this process is the first/only instance and should run the
    /// app. `false` if another instance is already running — we poked it to
    /// bring its window forward and Dart should `exit(0)`.
    pub first_instance: bool,
    /// `true` when `--toggle-window` launched us from cold (no other instance),
    /// so the window should be shown even if `silentStart` is on.
    pub force_visible: bool,
}

/// Single-instance guard + wake signal. Dart must call this *before*
/// `init_app_state`: if it returns `first_instance == false`, Dart must
/// `exit(0)` immediately (we already poked the running instance to show its
/// window). Otherwise Dart proceeds to `init_app_state`, passing
/// `force_visible` through so a cold `--toggle-window` launch shows the
/// window instead of starting hidden.
///
/// Reads `std::env::args()` directly (the process command line), so Dart does
/// not need to forward argv. A failure in the single-instance machinery is
/// logged inside and fails open — `first_instance == true` — so a broken lock
/// never blocks the app.
pub fn check_single_instance() -> SingleInstanceResult {
    match crate::core::single_instance::check() {
        crate::core::single_instance::Outcome::FirstInstance { force_visible } => {
            SingleInstanceResult {
                first_instance: true,
                force_visible,
            }
        }
        crate::core::single_instance::Outcome::SignalSent => SingleInstanceResult {
            first_instance: false,
            force_visible: false,
        },
    }
}

/// Initialize the Rust core: load history + settings, install the panic hook,
/// stash the global [`AppState`], and spawn the four background tasks
/// (clipboard poll, window-action worker, helper-status monitor, expired-item
/// cleaner). Idempotent-ish: a second call is a no-op (the [`OnceLock`] guards
/// the state), so it is safe if Dart retries after a hot restart.
pub fn init_app_state() -> Result<(), String> {
    if state::is_initialized() {
        log::write_log("init_app_state skipped: already initialized");
        return Ok(());
    }

    std::panic::set_hook(Box::new(|pi| log::write_log(&format!("PANIC: {}", pi))));

    log::write_log("ClipHist starting (flutter/rust core)...");
    let history = Arc::new(Mutex::new(clipboard_engine::load_history()));
    let startup_settings = settings_store::load_settings();
    log::write_log("load_history done");
    let counter = Arc::new(Mutex::new(
        history.lock().iter().map(|i| i.id).max().unwrap_or(0),
    ));
    let (window_action_tx, window_action_rx) = mpsc::channel::<()>();

    let state_app = AppState {
        history: history.clone(),
        counter: counter.clone(),
        settings: Arc::new(Mutex::new(startup_settings.clone())),
        window_action_tx,
    };
    if !state::set_state(state_app) {
        log::write_log("init_app_state skipped: another caller initialized state");
        return Ok(());
    }

    // If a second instance poked us during our own startup (before state
    // existed), its wake is buffered in the single-instance module — drain it
    // now so the window still pops up.
    crate::core::single_instance::drain_pending_wake();

    crate::core::background::spawn_all(history, counter, window_action_rx);

    // Global-hotkey registration lives in Dart's native `hotkey_manager`
    // plugin. That plugin executes on each platform's UI/event-loop thread;
    // constructing `global-hotkey` from an FRB worker thread was invalid on
    // macOS and thread-affine on Windows.
    if !startup_settings.double_tap_key.is_empty() {
        if let Err(e) = crate::core::shortcut_engine::start_double_tap_listener(
            &startup_settings.double_tap_key,
        ) {
            log::write_log(&format!("Startup double-tap listener failed: {}", e));
        }
    }

    log::write_log("init_app_state complete, background tasks spawned");
    Ok(())
}
