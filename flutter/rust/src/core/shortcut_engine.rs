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

// global-hotkey's Windows `GlobalHotKeyManager` holds a Win32 HWND
// (`*mut c_void`), which is `!Send` because HWNDs are thread-affine — a
// window and its RegisterHotKey binding belong to the thread that created
// them, and WM_HOTKEY is posted to that thread's message queue. That makes
// `Mutex<Option<GlobalHotKeyManager>>` non-`Sync`, so it cannot live in a
// `static` directly on Windows (the Linux X11 and macOS managers are `Send`
// and compile fine). We only ever touch the manager from the Flutter main
// thread: both call sites (init_app_state at startup, update_settings when
// the binding changes) are sync `#[frb]` functions, which FRB runs on the
// calling Dart isolate's thread — the platform/main thread that owns the
// Win32 message loop the manager relies on to dispatch WM_HOTKEY. So the
// `Send` impl below only satisfies the static's `Sync` bound; at runtime the
// manager is created, registered, and dropped on one and the same (main)
// thread and no HWND ever actually crosses threads. Keep all manager access
// confined to the main thread — do not call register_global_hotkey from a
// worker thread.
struct HotKeyManager(global_hotkey::GlobalHotKeyManager);
// SAFETY: see comment above — the manager is only accessed from the main
// thread; the Send impl is for the static's Sync requirement, not for
// actually moving the value across threads.
unsafe impl Send for HotKeyManager {}

static HOTKEY_MANAGER: Mutex<Option<HotKeyManager>> = Mutex::new(None);
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
    let manager = HotKeyManager(
        global_hotkey::GlobalHotKeyManager::new()
            .map_err(|e| format!("GlobalHotKeyManager::new failed: {}", e))?,
    );
    let hotkey = HotKey::new(Some(parsed.modifiers), parsed.code);
    manager
        .0
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
    start_double_tap_listener_platform(key_name)
}

#[cfg(target_os = "windows")]
fn start_double_tap_listener_platform(key_name: &str) -> Result<(), String> {
    windows_impl::start_double_tap_listener(key_name)
}
#[cfg(target_os = "linux")]
fn start_double_tap_listener_platform(key_name: &str) -> Result<(), String> {
    linux_impl::start_linux_double_tap_listener(key_name)
}
#[cfg(not(any(target_os = "windows", target_os = "linux")))]
fn start_double_tap_listener_platform(_key_name: &str) -> Result<(), String> {
    Ok(())
}

pub fn stop_double_tap_listener() {
    LISTENER_RUNNING.store(false, Ordering::SeqCst);
    #[cfg(target_os = "windows")]
    {
        windows_impl::stop_double_tap_listener();
    }
    #[cfg(target_os = "linux")]
    {
        linux_impl::stop_linux_double_tap_listener();
    }
    HELPER_CONNECTED.store(false, Ordering::SeqCst);
}

pub fn simulate_paste() -> Result<(), String> {
    simulate_paste_platform()
}

#[cfg(target_os = "windows")]
fn simulate_paste_platform() -> Result<(), String> {
    windows_impl::simulate_paste()
}
#[cfg(target_os = "linux")]
fn simulate_paste_platform() -> Result<(), String> {
    linux_impl::linux_simulate_paste()
}
#[cfg(not(any(target_os = "windows", target_os = "linux")))]
fn simulate_paste_platform() -> Result<(), String> {
    Err("Paste simulation is not supported on this platform".into())
}

#[cfg(target_os = "windows")]
mod windows_impl {
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

        let state: Arc<Mutex<DoubleTapState>> = Arc::new(Mutex::new(DoubleTapState {
            last_press: None,
            released: true,
        }));

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
                                    if now.duration_since(prev).as_millis() < DOUBLE_TAP_MS {
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

/// Linux double-tap + paste via the privileged `cliphist-evdev-helper`
/// binary (plan 3.1). The main process binds a Unix socket in the user-private
/// `$XDG_RUNTIME_DIR`, spawns the helper through `pkexec` (polkit prompts the
/// user once), and reads one `0x01` byte per detected double-tap. The socket
/// is bidirectional — `simulate_paste` writes `b'P'` and the root helper does
/// the uinput/wtype injection. Ported from the old `linux_impl` in
/// `src-tauri/src/shortcut.rs`; the only change is the helper path: instead of
/// re-entering `current_exe()` behind `--evdev-helper`, it resolves the
/// standalone `cliphist-evdev-helper` binary (build-time override, exe-dir
/// neighbor, then `PATH`).
#[cfg(target_os = "linux")]
mod linux_impl {
    use super::*;
    use std::io::{Read, Write};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::process::{Child, Command, Stdio};
    use std::sync::Mutex;

    /// Bidirectional stream to the root helper, kept so `simulate_paste` can
    /// send `b'P'` commands.
    static PASTE_STREAM: Mutex<Option<UnixStream>> = Mutex::new(None);
    static CHILD: Mutex<Option<Child>> = Mutex::new(None);
    static SOCKET_PATH: Mutex<String> = Mutex::new(String::new());

    /// Resolve the helper binary. Order:
    ///   1. `CLIPHIST_HELPER_PATH` build-time env override (M10 packaging pins
    ///      the installed absolute path).
    ///   2. next to the running executable (`<exe_dir>/cliphist-evdev-helper`).
    ///   3. bare `cliphist-evdev-helper` (resolved via `PATH`).
    fn resolve_helper_path() -> String {
        if let Some(p) = option_env!("CLIPHIST_HELPER_PATH") {
            if !p.is_empty() {
                return p.to_string();
            }
        }
        if let Ok(exe) = std::env::current_exe() {
            if let Some(dir) = exe.parent() {
                let candidate = dir.join("cliphist-evdev-helper");
                if candidate.exists() {
                    return candidate.to_string_lossy().to_string();
                }
            }
        }
        "cliphist-evdev-helper".to_string()
    }

    pub fn start_linux_double_tap_listener(key_name: &str) -> Result<(), String> {
        if LISTENER_RUNNING.load(Ordering::SeqCst) {
            stop_linux_double_tap_listener();
            std::thread::sleep(std::time::Duration::from_millis(200));
        }
        LISTENER_RUNNING.store(true, Ordering::SeqCst);

        let key_name = key_name.to_string();

        // $XDG_RUNTIME_DIR is per-user (0700) — not accessible to other users,
        // so the socket is only reachable by us and the root helper (which
        // bypasses perms). Avoids the predictable world-writable /tmp race.
        let xdg_runtime_dir = std::env::var("XDG_RUNTIME_DIR")
            .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }));
        let socket_path = format!(
            "{}/cliphist-dtap-{}.sock",
            xdg_runtime_dir,
            std::process::id()
        );
        let _ = std::fs::remove_file(&socket_path);
        *SOCKET_PATH.lock().unwrap() = socket_path.clone();

        let listener = UnixListener::bind(&socket_path)
            .map_err(|e| format!("Failed to create Unix socket: {}", e))?;

        let helper = resolve_helper_path();
        let wayland_display =
            std::env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "wayland-0".to_string());

        log::write_log(&format!(
            "Starting pkexec evdev helper: {} (socket: {})",
            helper, socket_path
        ));

        let child = Command::new("pkexec")
            .arg(&helper)
            .arg("--key")
            .arg(&key_name)
            .arg("--socket")
            .arg(&socket_path)
            .arg("--wayland-display")
            .arg(&wayland_display)
            .arg("--xdg-runtime-dir")
            .arg(&xdg_runtime_dir)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("Failed to spawn pkexec: {}", e))?;
        log::write_log(&format!("pkexec helper spawned, pid: {}", child.id()));
        *CHILD.lock().unwrap() = Some(child);

        std::thread::Builder::new()
            .name("double-tap-socket-listener".to_string())
            .spawn(move || {
                log::write_log("Waiting for evdev helper to connect...");
                let (mut stream, addr) = match listener.accept() {
                    Ok(s) => s,
                    Err(e) => {
                        log::write_log(&format!("Failed to accept helper connection: {}", e));
                        let _ = std::fs::remove_file(&socket_path);
                        LISTENER_RUNNING.store(false, Ordering::SeqCst);
                        return;
                    }
                };
                log::write_log(&format!("Evdev helper connected from {:?}", addr));
                HELPER_CONNECTED.store(true, Ordering::SeqCst);

                {
                    let mut paste_stream = PASTE_STREAM.lock().unwrap();
                    *paste_stream = stream.try_clone().ok();
                }

                let mut buf = [0u8; 1];
                loop {
                    if !LISTENER_RUNNING.load(Ordering::SeqCst) {
                        break;
                    }
                    match stream.read(&mut buf) {
                        Ok(1) => {
                            log::write_log("Double-tap notification from helper!");
                            state::request_window_action();
                        }
                        Ok(0) => {
                            log::write_log("Evdev helper disconnected");
                            break;
                        }
                        Ok(_) => {}
                        Err(e) => {
                            log::write_log(&format!("Socket read error: {}", e));
                            break;
                        }
                    }
                }

                drop(stream);
                {
                    let mut paste_stream = PASTE_STREAM.lock().unwrap();
                    *paste_stream = None;
                }
                let _ = std::fs::remove_file(&socket_path);
                // Reap the helper (pkexec may stick around briefly).
                let mut child_guard = CHILD.lock().unwrap();
                if let Some(mut child) = child_guard.take() {
                    let _ = child.wait();
                }
                HELPER_CONNECTED.store(false, Ordering::SeqCst);
                LISTENER_RUNNING.store(false, Ordering::SeqCst);
                log::write_log("Double-tap socket listener stopped");
            })
            .map_err(|e| format!("Failed to spawn socket listener thread: {}", e))?;

        Ok(())
    }

    pub fn stop_linux_double_tap_listener() {
        // Drop the paste stream + kill the helper so the socket thread exits.
        {
            let mut paste_stream = PASTE_STREAM.lock().unwrap();
            *paste_stream = None;
        }
        let mut child_guard = CHILD.lock().unwrap();
        if let Some(mut child) = child_guard.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let path = SOCKET_PATH.lock().unwrap().clone();
        if !path.is_empty() {
            let _ = std::fs::remove_file(&path);
        }
    }

    /// Send a paste command to the evdev helper via the bidirectional socket.
    /// The helper (root) performs the uinput/wtype injection.
    pub fn linux_simulate_paste() -> Result<(), String> {
        let mut guard = PASTE_STREAM
            .lock()
            .map_err(|e| format!("PASTE_STREAM lock poisoned: {}", e))?;
        if let Some(stream) = guard.as_mut() {
            stream
                .write_all(b"P")
                .map_err(|e| format!("Failed to send paste command to helper: {}", e))?;
            log::write_log("Sent paste command to evdev helper");
        } else {
            log::write_log(
                "No evdev helper connected; clipboard populated, user can paste manually",
            );
        }
        Ok(())
    }
}
