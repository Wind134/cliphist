//! Global hotkey + double-tap + paste injection, ported from the old
//! `src-tauri/src/shortcut.rs` minus the Tauri plugin layer.
//!
//! Scope by platform (matches the old split):
//!  - **Global hotkey**: `global-hotkey` crate, registered on Linux (X11) +
//!    Windows + macOS. Wayland sessions skip registration (plan 3.5) — there
//!    is no X11 global-grab on Wayland; v2 will use the GlobalShortcuts
//!    portal. The receiver thread turns a trigger into a
//!    [`crate::core::state::request_window_action`] (ShowAndRaise), which the
//!    Dart side performs.
//!  - **Double-tap**: Windows `rdev::grab` listener (ported verbatim). Linux
//!    double-tap goes through the privileged evdev helper (M8). macOS has no
//!    double-tap.
//!  - **simulate_paste**: Windows `rdev` Ctrl+V. macOS unsupported. Linux goes
//!    through the evdev helper (M8) — returns `Err` here until then.
//!
//! The hotkey string parser reuses [`crate::core::hotkey_parse`] for
//! validation; this module owns the enum mapping for actual registration.

use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use parking_lot::Mutex;

use crate::core::log;
use crate::core::state;

// ── Global hotkey (cross-platform) ─────────────────────────────────────────

static HOTKEY_MANAGER: Mutex<Option<global_hotkey::GlobalHotKeyManager>> = Mutex::new(None);
static HOTKEY_ID: AtomicU32 = AtomicU32::new(0);
static HOTKEY_RECEIVER_RUNNING: AtomicBool = AtomicBool::new(false);

/// (Re)register the global hotkey. Parses [shortcut_str] (e.g.
/// `Ctrl+Shift+V`), unregisters any prior binding, and spawns (once) the
/// event-receiver thread that turns triggers into window-action requests.
/// Wayland sessions skip registration and log a notice (plan 3.5).
pub fn register_global_hotkey(shortcut_str: &str) -> Result<(), String> {
    // Wayland degradation: global-hotkey relies on X11 grabs; on Wayland it
    // would no-op or fail. Skip cleanly and let the UI guide the user to a
    // system-level binding (M10 adds the `--toggle-window` CLI).
    if is_wayland() {
        log::write_log(&format!(
            "Skipping global hotkey registration on Wayland: {}",
            shortcut_str
        ));
        // Drop any previously registered manager just in case the session
        // changed under us.
        *HOTKEY_MANAGER.lock() = None;
        HOTKEY_ID.store(0, Ordering::SeqCst);
        return Ok(());
    }

    let parsed = match parse_hotkey(shortcut_str) {
        Some(p) => p,
        None => {
            // Empty / invalid — unregister whatever was there.
            *HOTKEY_MANAGER.lock() = None;
            HOTKEY_ID.store(0, Ordering::SeqCst);
            return Ok(());
        }
    };

    let mut manager_slot = HOTKEY_MANAGER.lock();
    // Re-create the manager so all prior hotkeys are dropped (unregistered).
    let manager = global_hotkey::GlobalHotKeyManager::new()
        .map_err(|e| format!("GlobalHotKeyManager::new failed: {}", e))?;
    let hotkey = HotKey::new(Some(parsed.modifiers), parsed.code);
    manager
        .register(hotkey)
        .map_err(|e| format!("register hotkey failed: {}", e))?;
    HOTKEY_ID.store(hotkey.id(), Ordering::SeqCst);
    *manager_slot = Some(manager);
    drop(manager_slot);

    ensure_receiver_thread();
    log::write_log(&format!("Registered global hotkey: {}", shortcut_str));
    Ok(())
}

fn ensure_receiver_thread() {
    if HOTKEY_RECEIVER_RUNNING.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::Builder::new()
        .name("hotkey-receiver".to_string())
        .spawn(|| {
            let receiver = global_hotkey::GlobalHotKeyEvent::receiver();
            while HOTKEY_RECEIVER_RUNNING.load(Ordering::SeqCst) {
                // Block until a hotkey event arrives (or the channel errors).
                match receiver.recv() {
                    Ok(event) => {
                        let current = HOTKEY_ID.load(Ordering::SeqCst);
                        if current != 0 && event.id == current {
                            log::write_log("Global hotkey triggered");
                            state::request_window_action();
                        }
                    }
                    Err(_) => {
                        // Sender dropped (manager replaced) — loop and try
                        // again; a new receiver is the same static handle.
                        std::thread::sleep(std::time::Duration::from_millis(100));
                    }
                }
            }
        })
        .ok();
}

fn is_wayland() -> bool {
    std::env::var("XDG_SESSION_TYPE")
        .unwrap_or_default()
        .eq_ignore_ascii_case("wayland")
}

struct ParsedHotkey {
    modifiers: Modifiers,
    code: Code,
}

fn parse_hotkey(s: &str) -> Option<ParsedHotkey> {
    let mut modifiers = Modifiers::empty();
    let mut code: Option<Code> = None;

    for part in s.split('+') {
        match part.trim().to_uppercase().as_str() {
            "COMMANDORCONTROL" | "CMDORCTRL" | "CTRL" | "CONTROL" => {
                modifiers |= Modifiers::CONTROL;
            }
            "COMMAND" | "CMD" | "SUPER" | "META" | "WIN" => {
                modifiers |= Modifiers::SUPER;
            }
            "SHIFT" => modifiers |= Modifiers::SHIFT,
            "ALT" | "OPTION" => modifiers |= Modifiers::ALT,
            k => {
                if let Some(c) = parse_key_code(k) {
                    code = Some(c);
                }
            }
        }
    }

    // Require at least one modifier — a bare key would hijack that key
    // system-wide (same guard as the old `parse_shortcut`).
    if modifiers.is_empty() {
        return None;
    }
    code.map(|c| ParsedHotkey { modifiers, code: c })
}

fn parse_key_code(k: &str) -> Option<Code> {
    Some(match k {
        "A" => Code::KeyA,
        "B" => Code::KeyB,
        "C" => Code::KeyC,
        "D" => Code::KeyD,
        "E" => Code::KeyE,
        "F" => Code::KeyF,
        "G" => Code::KeyG,
        "H" => Code::KeyH,
        "I" => Code::KeyI,
        "J" => Code::KeyJ,
        "K" => Code::KeyK,
        "L" => Code::KeyL,
        "M" => Code::KeyM,
        "N" => Code::KeyN,
        "O" => Code::KeyO,
        "P" => Code::KeyP,
        "Q" => Code::KeyQ,
        "R" => Code::KeyR,
        "S" => Code::KeyS,
        "T" => Code::KeyT,
        "U" => Code::KeyU,
        "V" => Code::KeyV,
        "W" => Code::KeyW,
        "X" => Code::KeyX,
        "Y" => Code::KeyY,
        "Z" => Code::KeyZ,
        "0" => Code::Digit0,
        "1" => Code::Digit1,
        "2" => Code::Digit2,
        "3" => Code::Digit3,
        "4" => Code::Digit4,
        "5" => Code::Digit5,
        "6" => Code::Digit6,
        "7" => Code::Digit7,
        "8" => Code::Digit8,
        "9" => Code::Digit9,
        "SPACE" => Code::Space,
        "ENTER" | "RETURN" => Code::Enter,
        "TAB" => Code::Tab,
        "ESC" | "ESCAPE" => Code::Escape,
        "BACKSPACE" => Code::Backspace,
        "F1" => Code::F1,
        "F2" => Code::F2,
        "F3" => Code::F3,
        "F4" => Code::F4,
        "F5" => Code::F5,
        "F6" => Code::F6,
        "F7" => Code::F7,
        "F8" => Code::F8,
        "F9" => Code::F9,
        "F10" => Code::F10,
        "F11" => Code::F11,
        "F12" => Code::F12,
        _ => return None,
    })
}

// ── Double-tap + paste (platform dispatch) ────────────────────────────────

static LISTENER_RUNNING: AtomicBool = AtomicBool::new(false);
static HELPER_CONNECTED: AtomicBool = AtomicBool::new(false);

pub fn helper_connected() -> bool {
    HELPER_CONNECTED.load(Ordering::SeqCst)
}

pub fn start_double_tap_listener(key_name: &str) -> Result<(), String> {
    if key_name.is_empty() {
        stop_double_tap_listener();
        return Ok(());
    }
    platform_impl::start_double_tap_listener(key_name)
}

pub fn stop_double_tap_listener() {
    LISTENER_RUNNING.store(false, Ordering::SeqCst);
    platform_impl::stop_double_tap_listener();
    HELPER_CONNECTED.store(false, Ordering::SeqCst);
}

pub fn simulate_paste() -> Result<(), String> {
    platform_impl::simulate_paste()
}

#[cfg(target_os = "windows")]
mod platform_impl {
    use super::*;
    use std::sync::Arc;
    use std::time::Instant;

    use parking_lot::Mutex;

    const DOUBLE_TAP_MS: u128 = 300;

    struct DoubleTapState {
        last_press: Option<Instant>,
        released: bool,
    }

    fn key_name_to_rdev(key_name: &str) -> Option<rdev::Key> {
        Some(match key_name {
            "Ctrl" => rdev::Key::ControlLeft,
            "Shift" => rdev::Key::ShiftLeft,
            "Alt" => rdev::Key::Alt,
            _ => return None,
        })
    }

    pub fn start_double_tap_listener(key_name: &str) -> Result<(), String> {
        let target_key = key_name_to_rdev(key_name)
            .ok_or_else(|| format!("Unsupported double-tap key: {}", key_name))?;

        if LISTENER_RUNNING.load(Ordering::SeqCst) {
            stop_double_tap_listener();
            std::thread::sleep(std::time::Duration::from_millis(200));
        }
        LISTENER_RUNNING.store(true, Ordering::SeqCst);
        HELPER_CONNECTED.store(true, Ordering::SeqCst);

        let state: Arc<Mutex<DoubleTapState>> =
            Arc::new(Mutex::new(DoubleTapState { last_press: None, released: true }));

        std::thread::Builder::new()
            .name("double-tap-listener".to_string())
            .spawn(move || {
                log::write_log(&format!(
                    "Starting Windows double-tap listener for key: {:?}",
                    target_key
                ));
                let result = rdev::grab(move |event| {
                    if !LISTENER_RUNNING.load(Ordering::SeqCst) {
                        return Some(event);
                    }
                    match event.event_type {
                        rdev::EventType::KeyPress(key) if key == target_key => {
                            let now = Instant::now();
                            let mut s = state.lock();
                            if s.released {
                                if let Some(prev) = s.last_press {
                                    if now.duration_since(prev).as_millis()
                                        < DOUBLE_TAP_MS
                                    {
                                        s.last_press = None;
                                        s.released = false;
                                        drop(s);
                                        log::write_log("Double-tap detected! (Windows)");
                                        state::request_window_action();
                                        return Some(event);
                                    }
                                }
                                s.last_press = Some(now);
                                s.released = false;
                            }
                        }
                        rdev::EventType::KeyRelease(key) if key == target_key => {
                            state.lock().released = true;
                        }
                        _ => {}
                    }
                    Some(event)
                });
                match result {
                    Ok(()) => log::write_log("Windows double-tap listener stopped normally"),
                    Err(e) => log::write_log(&format!("Windows double-tap grab error: {:?}", e)),
                }
                HELPER_CONNECTED.store(false, Ordering::SeqCst);
                LISTENER_RUNNING.store(false, Ordering::SeqCst);
            })
            .map_err(|e| format!("Failed to spawn double-tap listener thread: {}", e))?;
        Ok(())
    }

    pub fn stop_double_tap_listener() {
        // rdev::grab returns when the callback stops returning Some / the
        // listen loop ends; setting LISTENER_RUNNING=false makes the callback
        // pass events through and the grab returns on its own on thread exit.
        // There is no graceful cross-thread stop in rdev 0.5 besides letting
        // the thread finish; the flag prevents further triggers.
    }

    pub fn simulate_paste() -> Result<(), String> {
        use rdev::{simulate, EventType, Key};
        simulate(&EventType::KeyPress(Key::ControlLeft))
            .map_err(|e| format!("Simulate Ctrl press failed: {:?}", e))?;
        std::thread::sleep(std::time::Duration::from_millis(30));
        simulate(&EventType::KeyPress(Key::KeyV))
            .map_err(|e| format!("Simulate V press failed: {:?}", e))?;
        std::thread::sleep(std::time::Duration::from_millis(30));
        simulate(&EventType::KeyRelease(Key::KeyV))
            .map_err(|e| format!("Simulate V release failed: {:?}", e))?;
        std::thread::sleep(std::time::Duration::from_millis(30));
        simulate(&EventType::KeyRelease(Key::ControlLeft))
            .map_err(|e| format!("Simulate Ctrl release failed: {:?}", e))?;
        Ok(())
    }
}

#[cfg(not(target_os = "windows"))]
mod platform_impl {
    /// Non-Windows double-tap is handled by the privileged evdev helper
    /// (Linux, M8) or not at all (macOS). No-op here.
    pub fn start_double_tap_listener(_key_name: &str) -> Result<(), String> {
        Ok(())
    }

    pub fn stop_double_tap_listener() {}

    pub fn simulate_paste() -> Result<(), String> {
        // Linux paste is injected by the evdev helper (M8). macOS paste
        // injection is unsupported. Surface a clear error to Dart rather than
        // a silent no-op.
        #[cfg(target_os = "macos")]
        {
            Err("Paste simulation is not supported on macOS".into())
        }
        #[cfg(target_os = "linux")]
        {
            Err("Linux paste injection requires the evdev helper (M8)".into())
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        {
            Err("Paste simulation is not supported on this platform".into())
        }
    }
}