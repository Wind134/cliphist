use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

use parking_lot::Mutex;
use tauri::Manager;
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut};

static LISTENER_RUNNING: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone)]
pub struct ParsedShortcut {
    pub modifiers: Modifiers,
    pub code: Code,
}

pub fn parse_shortcut(shortcut_str: &str) -> Option<ParsedShortcut> {
    let parts: Vec<&str> = shortcut_str.split('+').collect();
    if parts.is_empty() {
        return None;
    }

    let mut modifiers = Modifiers::empty();
    let mut code = None;

    for part in parts {
        match part.trim().to_uppercase().as_str() {
            "COMMANDORCONTROL" | "CMDORCTRL" | "CTRL" => modifiers |= Modifiers::CONTROL,
            "COMMAND" | "CMD" | "SUPER" | "META" | "WIN" => modifiers |= Modifiers::META,
            "SHIFT" => modifiers |= Modifiers::SHIFT,
            "ALT" => modifiers |= Modifiers::ALT,
            k => {
                if let Some(c) = parse_key_code(k) {
                    code = Some(c);
                }
            }
        }
    }

    code.map(|c| ParsedShortcut { modifiers, code: c })
}

fn parse_key_code(key: &str) -> Option<Code> {
    match key.to_uppercase().as_str() {
        "A" => Some(Code::KeyA),
        "B" => Some(Code::KeyB),
        "C" => Some(Code::KeyC),
        "D" => Some(Code::KeyD),
        "E" => Some(Code::KeyE),
        "F" => Some(Code::KeyF),
        "G" => Some(Code::KeyG),
        "H" => Some(Code::KeyH),
        "I" => Some(Code::KeyI),
        "J" => Some(Code::KeyJ),
        "K" => Some(Code::KeyK),
        "L" => Some(Code::KeyL),
        "M" => Some(Code::KeyM),
        "N" => Some(Code::KeyN),
        "O" => Some(Code::KeyO),
        "P" => Some(Code::KeyP),
        "Q" => Some(Code::KeyQ),
        "R" => Some(Code::KeyR),
        "S" => Some(Code::KeyS),
        "T" => Some(Code::KeyT),
        "U" => Some(Code::KeyU),
        "V" => Some(Code::KeyV),
        "W" => Some(Code::KeyW),
        "X" => Some(Code::KeyX),
        "Y" => Some(Code::KeyY),
        "Z" => Some(Code::KeyZ),
        "0" => Some(Code::Digit0),
        "1" => Some(Code::Digit1),
        "2" => Some(Code::Digit2),
        "3" => Some(Code::Digit3),
        "4" => Some(Code::Digit4),
        "5" => Some(Code::Digit5),
        "6" => Some(Code::Digit6),
        "7" => Some(Code::Digit7),
        "8" => Some(Code::Digit8),
        "9" => Some(Code::Digit9),
        "SPACE" => Some(Code::Space),
        "ENTER" | "RETURN" => Some(Code::Enter),
        "ESCAPE" | "ESC" => Some(Code::Escape),
        "TAB" => Some(Code::Tab),
        _ => None,
    }
}

pub fn validate_shortcut(shortcut_str: &str) -> bool {
    parse_shortcut(shortcut_str).is_some()
}

pub fn register_global_shortcut(app: &tauri::App, shortcut_str: &str) -> Result<(), String> {
    if let Some(parsed) = parse_shortcut(shortcut_str) {
        let shortcut = Shortcut::new(Some(parsed.modifiers), parsed.code);
        let app_handle = app.handle().clone();
        app.global_shortcut()
            .on_shortcut(shortcut, move |_app, _shortcut, _event| {
                crate::log::write_log("Global shortcut triggered");
                if let Some(window) = app_handle.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            })
            .map_err(|e| e.to_string())?;
        crate::log::write_log(&format!("Registered global shortcut: {}", shortcut_str));
    }
    Ok(())
}

// --- Double-tap modifier key detection ---

const DOUBLE_TAP_MS: u128 = 300;

fn key_name_to_rdev(key_name: &str) -> Option<rdev::Key> {
    match key_name {
        "Ctrl" => Some(rdev::Key::ControlLeft),
        "Shift" => Some(rdev::Key::ShiftLeft),
        "Alt" => Some(rdev::Key::Alt),
        _ => None,
    }
}

pub fn start_double_tap_listener<F: Fn() + Send + Sync + 'static>(
    key_name: &str,
    on_trigger: F,
) -> Result<(), String> {
    let target_key = key_name_to_rdev(key_name)
        .ok_or_else(|| format!("Unsupported double-tap key: {}", key_name))?;

    if LISTENER_RUNNING.load(Ordering::SeqCst) {
        stop_double_tap_listener();
        std::thread::sleep(std::time::Duration::from_millis(200));
    }

    LISTENER_RUNNING.store(true, Ordering::SeqCst);

    let last_press: Arc<Mutex<Option<Instant>>> = Arc::new(Mutex::new(None));
    let callback = Arc::new(on_trigger);

    std::thread::Builder::new()
        .name("double-tap-listener".to_string())
        .spawn(move || {
            crate::log::write_log(&format!(
                "Starting double-tap listener for key: {:?}",
                target_key
            ));

            let result = rdev::grab(move |event| {
                if !LISTENER_RUNNING.load(Ordering::SeqCst) {
                    return Some(event);
                }

                if let rdev::EventType::KeyPress(key) = event.event_type {
                    if key == target_key {
                        let now = Instant::now();
                        let mut last = last_press.lock();
                        if let Some(prev) = *last {
                            if now.duration_since(prev).as_millis() < DOUBLE_TAP_MS {
                                *last = None;
                                crate::log::write_log("Double-tap detected!");
                                callback();
                                return Some(event);
                            }
                        }
                        *last = Some(now);
                    }
                }

                Some(event)
            });

            match result {
                Ok(()) => crate::log::write_log("Double-tap listener stopped normally"),
                Err(e) => crate::log::write_log(&format!("Double-tap grab error: {:?}", e)),
            }

            LISTENER_RUNNING.store(false, Ordering::SeqCst);
        })
        .map_err(|e| format!("Failed to spawn double-tap listener thread: {}", e))?;

    Ok(())
}

pub fn stop_double_tap_listener() {
    LISTENER_RUNNING.store(false, Ordering::SeqCst);
    crate::log::write_log("Double-tap listener stop requested");
}
