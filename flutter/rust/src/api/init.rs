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

/// Initialize the Rust core: load history + settings, install the panic hook,
/// stash the global [`AppState`], and spawn the four background tasks
/// (clipboard poll, window-action worker, helper-status monitor, expired-item
/// cleaner). Idempotent-ish: a second call is a no-op (the [`OnceLock`] guards
/// the state), so it is safe if Dart retries after a hot restart.
pub fn init_app_state() -> Result<(), String> {
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
        settings: Arc::new(Mutex::new(startup_settings)),
        window_action_tx,
    };
    state::set_state(state_app);

    crate::core::background::spawn_all(history, counter, window_action_rx);

    // Register the startup hotkey + double-tap listener (M7). Failures are
    // logged only — the app still runs; the user can fix the binding in
    // settings. Wayland skips the hotkey (logged inside).
    let startup_settings = settings_store::load_settings();
    if !startup_settings.hotkey.is_empty() {
        if let Err(e) = crate::core::shortcut_engine::register_global_hotkey(
            &startup_settings.hotkey,
        ) {
            log::write_log(&format!("Startup hotkey register failed: {}", e));
        }
    }
    if !startup_settings.double_tap_key.is_empty() {
        if let Err(e) = crate::core::shortcut_engine::start_double_tap_listener(
            &startup_settings.double_tap_key,
        ) {
            log::write_log(&format!(
                "Startup double-tap listener failed: {}",
                e
            ));
        }
    }

    log::write_log("init_app_state complete, background tasks spawned");
    Ok(())
}
