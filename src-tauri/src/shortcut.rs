use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut};

// ============================================================================
// Shared types and helpers (both platforms)
// ============================================================================

static LISTENER_RUNNING: AtomicBool = AtomicBool::new(false);
static LISTENER_GENERATION: AtomicU64 = AtomicU64::new(0);
pub static HELPER_CONNECTED: AtomicBool = AtomicBool::new(false);
static STOP_EPOCH: AtomicU64 = AtomicU64::new(0);
static EXIT_EPOCH: AtomicU64 = AtomicU64::new(0);

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

    // Require at least one modifier. A bare key (e.g. "V") would register as a
    // global shortcut and hijack that key system-wide, breaking normal typing.
    if modifiers.is_empty() {
        return None;
    }

    code.map(|c| ParsedShortcut { modifiers, code: c })
}

#[derive(Debug, Clone)]
pub struct ParsedShortcut {
    pub modifiers: Modifiers,
    pub code: Code,
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

pub fn register_global_shortcut(app: &tauri::AppHandle, shortcut_str: &str) -> Result<(), String> {
    if let Some(parsed) = parse_shortcut(shortcut_str) {
        let shortcut = Shortcut::new(Some(parsed.modifiers), parsed.code);
        let app_handle = app.clone();

        // Unregister all existing shortcuts first to avoid duplicates
        app.global_shortcut()
            .unregister_all()
            .map_err(|e| e.to_string())?;

        app.global_shortcut()
            .on_shortcut(shortcut, move |_app, _shortcut, _event| {
                crate::log::write_log("Global shortcut triggered");
                crate::focus_main_window(&app_handle);
            })
            .map_err(|e| e.to_string())?;
        crate::log::write_log(&format!("Registered global shortcut: {}", shortcut_str));
    }
    Ok(())
}

// ============================================================================
// Double-tap state (shared between platforms)
// ============================================================================

#[cfg_attr(target_os = "linux", allow(dead_code))]
const DOUBLE_TAP_MS: u128 = 300;

// `DoubleTapState` is defined once in `crate::state` and re-used by the
// platform-specific listeners below (each module has its own `use`).

// ============================================================================
// Platform-specific: Linux — evdev-based double-tap + uinput simulate_paste
// ============================================================================

#[cfg(target_os = "linux")]
mod linux_impl {
    use std::io::{Read, Write};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::sync::atomic::Ordering;
    use std::sync::Mutex;

    /// Bidirectional stream to the pkexec helper, stored so `simulate_paste`
    /// can send paste commands to the root process.
    static PASTE_STREAM: Mutex<Option<UnixStream>> = Mutex::new(None);

    /// Start the double-tap listener by spawning a privileged helper via pkexec.
    ///
    /// The helper binary is the same executable, invoked as:
    ///   pkexec cliphist --evdev-helper --key <KEY> --socket <SOCKET_PATH>
    ///
    /// pkexec triggers a polkit authentication dialog. Once authorized, the helper
    /// runs as root, reads /dev/input/event* via evdev, and writes a single byte to
    /// the Unix socket for each detected double-tap.
    ///
    /// The main process listens on the socket and fires `on_trigger`.
    pub fn start_linux_double_tap_listener<F: Fn() + Send + Sync + 'static>(
        key_name: &str,
        on_trigger: F,
    ) -> Result<(), String> {
        if super::LISTENER_RUNNING.load(Ordering::SeqCst) {
            super::stop_and_wait_double_tap_listener(2000);
        }

        super::LISTENER_RUNNING.store(true, Ordering::SeqCst);

        let key_name = key_name.to_string();

        // Resolve the user-private runtime dir first so the socket can live in
        // it. /tmp is world-writable and predictable, which invites a
        // symlink/race attack against the root helper; $XDG_RUNTIME_DIR is
        // per-user (0700) and not accessible to other users, so the socket is
        // only reachable by us and by the root helper (which bypasses perms).
        let xdg_runtime_dir = std::env::var("XDG_RUNTIME_DIR")
            .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }));

        // Create a Unix socket for the helper to notify us. Place it in the
        // user-private runtime dir instead of /tmp to avoid a predictable
        // world-writable-path symlink race.
        let socket_path = format!(
            "{}/cliphist-dtap-{}.sock",
            xdg_runtime_dir,
            std::process::id()
        );
        // Clean up any stale socket
        let _ = std::fs::remove_file(&socket_path);

        let listener = UnixListener::bind(&socket_path)
            .map_err(|e| format!("Failed to create Unix socket: {}", e))?;

        crate::log::write_log(&format!(
            "Starting pkexec evdev helper, socket: {}",
            socket_path
        ));

        // Get the path to the current executable
        let exe = std::env::current_exe()
            .map_err(|e| format!("Failed to get current exe path: {}", e))?;

        // Spawn the helper via pkexec
        let wayland_display = std::env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "wayland-0".to_string());

        let mut child = std::process::Command::new("pkexec")
            .arg(&exe)
            .arg("--evdev-helper")
            .arg("--key")
            .arg(&key_name)
            .arg("--socket")
            .arg(&socket_path)
            .arg("--wayland-display")
            .arg(&wayland_display)
            .arg("--xdg-runtime-dir")
            .arg(&xdg_runtime_dir)
            .spawn()
            .map_err(|e| format!("Failed to spawn pkexec: {}", e))?;

        crate::log::write_log(&format!(
            "pkexec helper spawned, pid: {}",
            child.id()
        ));

        // Spawn a thread to wait for the helper to connect and send notifications
        std::thread::Builder::new()
            .name("double-tap-socket-listener".to_string())
            .spawn(move || {
                crate::log::write_log("Waiting for evdev helper to connect...");

                // Accept one connection from the helper
                let (mut stream, addr) = match listener.accept() {
                    Ok(s) => s,
                    Err(e) => {
                        crate::log::write_log(&format!(
                            "Failed to accept helper connection: {}",
                            e
                        ));
                        let _ = std::fs::remove_file(&socket_path);
                        super::LISTENER_RUNNING.store(false, Ordering::SeqCst);
                        return;
                    }
                };
                crate::log::write_log(&format!(
                    "Evdev helper connected from {:?}",
                    addr
                ));
                super::HELPER_CONNECTED.store(true, Ordering::SeqCst);

                // Clone the stream for paste commands
                {
                    let mut paste_stream = PASTE_STREAM.lock().unwrap();
                    *paste_stream = stream.try_clone().ok();
                }

                // Read notification bytes in a loop. Each byte = one double-tap.
                let mut buf = [0u8; 1];
                loop {
                    if !super::LISTENER_RUNNING.load(Ordering::SeqCst) {
                        break;
                    }
                    match stream.read(&mut buf) {
                        Ok(1) => {
                            crate::log::write_log("Double-tap notification from helper!");
                            on_trigger();
                        }
                        Ok(0) => {
                            crate::log::write_log("Evdev helper disconnected");
                            break;
                        }
                        Ok(n) => {
                            crate::log::write_log(&format!(
                                "Unexpected read size: {}",
                                n
                            ));
                        }
                        Err(e) => {
                            crate::log::write_log(&format!(
                                "Socket read error: {}",
                                e
                            ));
                            break;
                        }
                    }
                }

                // Cleanup
                drop(stream);
                // Clear the paste stream
                {
                    let mut paste_stream = PASTE_STREAM.lock().unwrap();
                    *paste_stream = None;
                }
                let _ = std::fs::remove_file(&socket_path);
                // Wait for the helper to exit (pkexec may stick around)
                let _ = child.wait();
                super::HELPER_CONNECTED.store(false, Ordering::SeqCst);
                super::LISTENER_RUNNING.store(false, Ordering::SeqCst);
                super::EXIT_EPOCH.store(super::STOP_EPOCH.load(Ordering::SeqCst), Ordering::SeqCst);
                crate::log::write_log("Double-tap socket listener stopped");
            })
            .map_err(|e| format!("Failed to spawn socket listener thread: {}", e))?;

        Ok(())
    }

    /// Send a paste command to the evdev helper via the bidirectional socket.
    /// The helper (running as root) performs the actual uinput injection.
    pub fn linux_simulate_paste() -> Result<(), String> {
        let mut guard = PASTE_STREAM
            .lock()
            .map_err(|e| format!("PASTE_STREAM lock poisoned: {}", e))?;

        if let Some(stream) = guard.as_mut() {
            stream
                .write_all(b"P")
                .map_err(|e| format!("Failed to send paste command to helper: {}", e))?;
            crate::log::write_log("Sent paste command to evdev helper");
        } else {
            crate::log::write_log("No evdev helper connected; clipboard populated, user can paste manually");
        }
        Ok(())
    }
}

// ============================================================================
// Platform-specific: Windows — rdev-based double-tap + simulate_paste
// ============================================================================

#[cfg(target_os = "windows")]
mod windows_impl {
    use crate::state::DoubleTapState;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::time::Instant;

    use parking_lot::Mutex;

    fn key_name_to_rdev(key_name: &str) -> Option<rdev::Key> {
        match key_name {
            "Ctrl" => Some(rdev::Key::ControlLeft),
            "Shift" => Some(rdev::Key::ShiftLeft),
            "Alt" => Some(rdev::Key::Alt),
            _ => None,
        }
    }

    pub fn start_windows_double_tap_listener<F: Fn() + Send + Sync + 'static>(
        key_name: &str,
        on_trigger: F,
    ) -> Result<(), String> {
        let target_key = key_name_to_rdev(key_name)
            .ok_or_else(|| format!("Unsupported double-tap key: {}", key_name))?;

        if super::LISTENER_RUNNING.load(Ordering::SeqCst) {
            super::stop_double_tap_listener();
            std::thread::sleep(std::time::Duration::from_millis(200));
        }

        super::LISTENER_RUNNING.store(true, Ordering::SeqCst);
        super::HELPER_CONNECTED.store(true, Ordering::SeqCst);

        let state: Arc<Mutex<DoubleTapState>> = Arc::new(Mutex::new(DoubleTapState {
            last_press: None,
            released: true,
        }));
        let callback = Arc::new(on_trigger);

        std::thread::Builder::new()
            .name("double-tap-listener".to_string())
            .spawn(move || {
                crate::log::write_log(&format!(
                    "Starting Windows double-tap listener for key: {:?}",
                    target_key
                ));

                let result = rdev::grab(move |event| {
                    if !super::LISTENER_RUNNING.load(Ordering::SeqCst) {
                        return Some(event);
                    }

                    match event.event_type {
                        rdev::EventType::KeyPress(key) if key == target_key => {
                            let now = Instant::now();
                            let mut s = state.lock();
                            if s.released {
                                if let Some(prev) = s.last_press {
                                    if now.duration_since(prev).as_millis() < super::DOUBLE_TAP_MS {
                                        s.last_press = None;
                                        s.released = false;
                                        crate::log::write_log("Double-tap detected! (Windows)");
                                        drop(s);
                                        callback();
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
                    Ok(()) => crate::log::write_log("Windows double-tap listener stopped normally"),
                    Err(e) => crate::log::write_log(&format!(
                        "Windows double-tap grab error: {:?}",
                        e
                    )),
                }

                super::HELPER_CONNECTED.store(false, Ordering::SeqCst);
                super::LISTENER_RUNNING.store(false, Ordering::SeqCst);
                super::EXIT_EPOCH.store(super::STOP_EPOCH.load(Ordering::SeqCst), Ordering::SeqCst);
            })
            .map_err(|e| format!("Failed to spawn double-tap listener thread: {}", e))?;

        Ok(())
    }

    pub fn windows_simulate_paste() -> Result<(), String> {
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

// ============================================================================
// Public API — dispatches to platform impl
// ============================================================================

#[cfg(target_os = "linux")]
pub fn start_double_tap_listener<F: Fn() + Send + Sync + 'static>(
    key_name: &str,
    on_trigger: F,
) -> Result<(), String> {
    linux_impl::start_linux_double_tap_listener(key_name, on_trigger)
}

#[cfg(target_os = "windows")]
pub fn start_double_tap_listener<F: Fn() + Send + Sync + 'static>(
    key_name: &str,
    on_trigger: F,
) -> Result<(), String> {
    windows_impl::start_windows_double_tap_listener(key_name, on_trigger)
}

#[cfg(target_os = "macos")]
pub fn start_double_tap_listener<F: Fn() + Send + Sync + 'static>(
    _key_name: &str,
    _on_trigger: F,
) -> Result<(), String> {
    Err("Double-tap listener is not supported on macOS".into())
}

#[cfg_attr(target_os = "linux", allow(dead_code))]
pub fn stop_double_tap_listener() {
    LISTENER_RUNNING.store(false, Ordering::SeqCst);
    HELPER_CONNECTED.store(false, Ordering::SeqCst);
    LISTENER_GENERATION.fetch_add(1, Ordering::SeqCst);
    crate::log::write_log("Double-tap listener stop requested");
}

/// Stop the listener and wait for the listener thread to actually exit.
/// Uses an epoch-based acknowledgment instead of a fixed sleep.
pub fn stop_and_wait_double_tap_listener(timeout_ms: u64) {
    if !LISTENER_RUNNING.load(Ordering::SeqCst) {
        return;
    }
    let epoch = STOP_EPOCH.fetch_add(1, Ordering::SeqCst) + 1;
    LISTENER_RUNNING.store(false, Ordering::SeqCst);
    HELPER_CONNECTED.store(false, Ordering::SeqCst);
    LISTENER_GENERATION.fetch_add(1, Ordering::SeqCst);
    crate::log::write_log("Double-tap listener stop requested (wait)");

    let deadline = std::time::Instant::now()
        + std::time::Duration::from_millis(timeout_ms);
    while EXIT_EPOCH.load(Ordering::SeqCst) < epoch {
        if std::time::Instant::now() >= deadline {
            crate::log::write_log("stop_and_wait timed out, proceeding anyway");
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
}

pub fn is_helper_connected() -> bool {
    HELPER_CONNECTED.load(Ordering::SeqCst)
}

#[allow(dead_code)]
pub fn is_listener_running() -> bool {
    LISTENER_RUNNING.load(Ordering::SeqCst)
}

pub fn listener_generation() -> u64 {
    LISTENER_GENERATION.load(Ordering::SeqCst)
}

#[cfg(target_os = "linux")]
pub fn simulate_paste() -> Result<(), String> {
    linux_impl::linux_simulate_paste()
}

#[cfg(target_os = "windows")]
pub fn simulate_paste() -> Result<(), String> {
    windows_impl::windows_simulate_paste()
}

#[cfg(target_os = "macos")]
pub fn simulate_paste() -> Result<(), String> {
    Err("Paste simulation is not supported on macOS".into())
}
