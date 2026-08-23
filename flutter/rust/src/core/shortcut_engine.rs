//! Double-tap detection + paste injection. Global hotkeys are registered by
//! Dart's native plugin on the platform event-loop thread.
//!
//! Scope by platform:
//!  - **Double-tap**: Windows + macOS both use `rdev::grab` (a global key
//!    tap listener); macOS requires the app to be granted Accessibility
//!    permission or `grab` errors out. Linux double-tap goes through the
//!    privileged evdev helper.
//!  - **simulate_paste**: Windows `rdev` Ctrl+V, macOS `rdev` Cmd+V, Linux
//!    through the evdev helper. Other platforms return `Err`.
#[cfg(target_os = "linux")]
use std::sync::atomic::AtomicU64;
#[cfg(any(target_os = "windows", target_os = "macos"))]
use std::sync::atomic::AtomicU8;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::core::log;
use crate::core::state;

// ── Double-tap + paste (platform dispatch) ────────────────────────────────

static LISTENER_RUNNING: AtomicBool = AtomicBool::new(false);
static HELPER_CONNECTED: AtomicBool = AtomicBool::new(false);
static GAME_MODE: AtomicBool = AtomicBool::new(false);

/// Suspend only double-tap wake detection. Clipboard capture, the regular
/// global hotkey and simulated paste remain available while game mode is on.
pub fn set_game_mode(enabled: bool) {
    let previous = GAME_MODE.swap(enabled, Ordering::SeqCst);
    if previous != enabled {
        log::write_log(if enabled {
            "Game mode enabled: double-tap wake suspended"
        } else {
            "Game mode disabled: double-tap wake resumed"
        });
    }
}

fn double_tap_wake_allowed() -> bool {
    !GAME_MODE.load(Ordering::SeqCst)
}

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

#[cfg(any(target_os = "windows", target_os = "macos"))]
fn start_double_tap_listener_platform(key_name: &str) -> Result<(), String> {
    rdev_impl::start_double_tap_listener(key_name)
}
#[cfg(target_os = "linux")]
fn start_double_tap_listener_platform(key_name: &str) -> Result<(), String> {
    linux_impl::start_linux_double_tap_listener(key_name)
}
#[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
fn start_double_tap_listener_platform(_key_name: &str) -> Result<(), String> {
    Ok(())
}

pub fn stop_double_tap_listener() {
    LISTENER_RUNNING.store(false, Ordering::SeqCst);
    #[cfg(any(target_os = "windows", target_os = "macos"))]
    {
        rdev_impl::stop_double_tap_listener();
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

#[cfg(any(target_os = "windows", target_os = "macos"))]
fn simulate_paste_platform() -> Result<(), String> {
    rdev_impl::simulate_paste()
}
#[cfg(target_os = "linux")]
fn simulate_paste_platform() -> Result<(), String> {
    linux_impl::linux_simulate_paste()
}
#[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
fn simulate_paste_platform() -> Result<(), String> {
    Err("Paste simulation is not supported on this platform".into())
}

/// Shared `rdev` backend for Windows + macOS. Both expose `rdev::grab` (a
/// global key tap listener) and `rdev::simulate` (synthetic key events), so
/// the double-tap detector and the paste injection are byte-for-byte
/// identical between the two — only the paste modifier differs (Ctrl on
/// Windows, Cmd on macOS). macOS requires the app to be granted Accessibility
/// permission; without it `grab` returns an error (logged below) and the
/// "双击快捷键" status dot stays grey, mirroring the Linux "needs
/// authorization" UX.
#[cfg(any(target_os = "windows", target_os = "macos"))]
mod rdev_impl {
    use super::*;
    use std::time::Instant;

    use parking_lot::Mutex;

    const DOUBLE_TAP_MS: u128 = 420;
    const TARGET_DISABLED: u8 = 0;
    const TARGET_CTRL: u8 = 1;
    const TARGET_SHIFT: u8 = 2;
    const TARGET_ALT: u8 = 3;

    static TARGET_KEY: AtomicU8 = AtomicU8::new(TARGET_DISABLED);
    static RDEV_THREAD_STARTED: AtomicBool = AtomicBool::new(false);

    struct DoubleTapState {
        last_press: Option<Instant>,
        released: bool,
        target: u8,
    }

    fn key_name_to_code(key_name: &str) -> Option<u8> {
        Some(match key_name {
            "Ctrl" => TARGET_CTRL,
            "Shift" => TARGET_SHIFT,
            "Alt" => TARGET_ALT,
            _ => return None,
        })
    }

    fn key_matches(code: u8, key: rdev::Key) -> bool {
        matches!(
            (code, key),
            (TARGET_CTRL, rdev::Key::ControlLeft)
                | (TARGET_CTRL, rdev::Key::ControlRight)
                | (TARGET_SHIFT, rdev::Key::ShiftLeft)
                | (TARGET_SHIFT, rdev::Key::ShiftRight)
                | (TARGET_ALT, rdev::Key::Alt)
                | (TARGET_ALT, rdev::Key::AltGr)
        )
    }

    /// The modifier held during a synthetic paste — Ctrl on Windows, Cmd on
    /// macOS (the platform's copy/paste modifier).
    #[cfg(target_os = "windows")]
    const PASTE_MOD: rdev::Key = rdev::Key::ControlLeft;
    #[cfg(target_os = "macos")]
    const PASTE_MOD: rdev::Key = rdev::Key::MetaLeft;

    pub fn start_double_tap_listener(key_name: &str) -> Result<(), String> {
        let target_code = key_name_to_code(key_name)
            .ok_or_else(|| format!("Unsupported double-tap key: {}", key_name))?;
        TARGET_KEY.store(target_code, Ordering::SeqCst);
        LISTENER_RUNNING.store(true, Ordering::SeqCst);

        // rdev 0.5 exposes no cross-thread stop for its blocking event loop.
        // Keep exactly one hook thread for the process lifetime and update its
        // target atomically; spawning a replacement leaked the old hook and
        // made both the old and new double-tap keys active.
        if RDEV_THREAD_STARTED.swap(true, Ordering::SeqCst) {
            HELPER_CONNECTED.store(true, Ordering::SeqCst);
            return Ok(());
        }

        let state = Mutex::new(DoubleTapState {
            last_press: None,
            released: true,
            target: target_code,
        });

        std::thread::Builder::new()
            .name("double-tap-listener".to_string())
            .spawn(move || {
                log::write_log("Starting persistent rdev double-tap listener");
                HELPER_CONNECTED.store(true, Ordering::SeqCst);
                let result = rdev::grab(move |event| {
                    let target = TARGET_KEY.load(Ordering::SeqCst);
                    if target == TARGET_DISABLED {
                        return Some(event);
                    }
                    if !double_tap_wake_allowed() {
                        let mut s = state.lock();
                        s.last_press = None;
                        s.released = true;
                        return Some(event);
                    }
                    {
                        let mut s = state.lock();
                        if s.target != target {
                            s.target = target;
                            s.last_press = None;
                            s.released = true;
                        }
                    }
                    match event.event_type {
                        rdev::EventType::KeyPress(key) if key_matches(target, key) => {
                            let now = Instant::now();
                            let mut s = state.lock();
                            if s.released {
                                if let Some(prev) = s.last_press {
                                    if now.duration_since(prev).as_millis() < DOUBLE_TAP_MS {
                                        s.last_press = None;
                                        s.released = false;
                                        drop(s);
                                        log::write_log("Double-tap detected! (rdev)");
                                        state::request_window_action();
                                        return Some(event);
                                    }
                                }
                                s.last_press = Some(now);
                                s.released = false;
                            }
                        }
                        rdev::EventType::KeyRelease(key) if key_matches(target, key) => {
                            state.lock().released = true;
                        }
                        _ => {}
                    }
                    Some(event)
                });
                match result {
                    Ok(()) => log::write_log("rdev double-tap listener stopped normally"),
                    Err(e) => log::write_log(&format!("rdev double-tap grab error: {:?}", e)),
                }
                HELPER_CONNECTED.store(false, Ordering::SeqCst);
                LISTENER_RUNNING.store(false, Ordering::SeqCst);
                RDEV_THREAD_STARTED.store(false, Ordering::SeqCst);
            })
            .map_err(|e| {
                RDEV_THREAD_STARTED.store(false, Ordering::SeqCst);
                LISTENER_RUNNING.store(false, Ordering::SeqCst);
                format!("Failed to spawn double-tap listener thread: {}", e)
            })?;
        Ok(())
    }

    pub fn stop_double_tap_listener() {
        TARGET_KEY.store(TARGET_DISABLED, Ordering::SeqCst);
        HELPER_CONNECTED.store(false, Ordering::SeqCst);
    }

    pub fn simulate_paste() -> Result<(), String> {
        use rdev::{simulate, EventType, Key};
        simulate(&EventType::KeyPress(PASTE_MOD))
            .map_err(|e| format!("Simulate modifier press failed: {:?}", e))?;
        std::thread::sleep(std::time::Duration::from_millis(30));
        if let Err(e) = simulate(&EventType::KeyPress(Key::KeyV)) {
            let _ = simulate(&EventType::KeyRelease(PASTE_MOD));
            return Err(format!("Simulate V press failed: {:?}", e));
        }
        std::thread::sleep(std::time::Duration::from_millis(30));
        let release_v = simulate(&EventType::KeyRelease(Key::KeyV));
        std::thread::sleep(std::time::Duration::from_millis(30));
        let release_mod = simulate(&EventType::KeyRelease(PASTE_MOD));
        release_v.map_err(|e| format!("Simulate V release failed: {:?}", e))?;
        release_mod.map_err(|e| format!("Simulate modifier release failed: {:?}", e))?;
        Ok(())
    }
}

/// Linux double-tap + paste via the privileged `cliphist-evdev-helper`
/// binary. The main process binds a Unix socket in the user-private
/// `$XDG_RUNTIME_DIR`, spawns the helper through `pkexec` (polkit prompts the
/// user once), and reads `b'D'` per detected double-tap. The socket is
/// bidirectional: `simulate_paste` writes `b'P'`, then waits for the helper's
/// `b'S'`/`b'F'` injection result instead of reporting unconditional success.
/// The helper path resolves a standalone `cliphist-evdev-helper` binary using
/// a build-time override, a trusted executable-directory neighbor, then the
/// fixed packaged path. Every candidate must be root-owned and non-writable.
#[cfg(target_os = "linux")]
mod linux_impl {
    use super::*;
    use parking_lot::Mutex;
    use std::io::{Read, Write};
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    use std::os::unix::io::AsRawFd;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};
    use std::sync::mpsc;

    /// Bidirectional stream to the root helper, kept so `simulate_paste` can
    /// send `b'P'` commands.
    static GENERATION: AtomicU64 = AtomicU64::new(0);
    static PASTE_STREAM: Mutex<Option<(u64, UnixStream)>> = Mutex::new(None);
    static PASTE_ACK: Mutex<Option<(u64, mpsc::Receiver<bool>)>> = Mutex::new(None);
    static PASTE_REQUEST: Mutex<()> = Mutex::new(());
    static CHILD: Mutex<Option<(u64, Child)>> = Mutex::new(None);
    static SOCKET_PATH: Mutex<Option<(u64, String)>> = Mutex::new(None);

    /// Resolve the helper binary. Order:
    ///   1. `CLIPHIST_HELPER_PATH` build-time environment override (packaging
    ///      pins the installed absolute path).
    ///   2. next to the running executable (`<exe_dir>/cliphist-evdev-helper`).
    ///   3. the fixed packaged path.
    fn resolve_helper_path() -> Result<PathBuf, String> {
        if let Some(p) = option_env!("CLIPHIST_HELPER_PATH") {
            if !p.is_empty() {
                return validate_helper_path(Path::new(p));
            }
        }
        if let Ok(exe) = std::env::current_exe() {
            if let Some(dir) = exe.parent() {
                let candidate = dir.join("cliphist-evdev-helper");
                if candidate.exists() {
                    return validate_helper_path(&candidate);
                }
            }
        }
        validate_helper_path(Path::new("/opt/cliphist/cliphist-evdev-helper"))
    }

    fn validate_helper_path(path: &Path) -> Result<PathBuf, String> {
        let canonical = std::fs::canonicalize(path)
            .map_err(|e| format!("Cannot resolve evdev helper {path:?}: {e}"))?;
        let metadata = std::fs::metadata(&canonical)
            .map_err(|e| format!("Cannot inspect evdev helper {canonical:?}: {e}"))?;
        if !metadata.is_file() || metadata.uid() != 0 || metadata.mode() & 0o022 != 0 {
            return Err(format!(
                "Refusing untrusted evdev helper {canonical:?}: expected a root-owned, non-writable regular file"
            ));
        }
        Ok(canonical)
    }

    pub fn start_linux_double_tap_listener(key_name: &str) -> Result<(), String> {
        // Invalidate and reap the previous generation first. A generation id
        // prevents a late cleanup from an old listener from clearing the new
        // listener's child/socket/status after the setting changes quickly.
        stop_linux_double_tap_listener();
        let key_name = key_name.to_string();

        // $XDG_RUNTIME_DIR is per-user (0700) — not accessible to other users,
        // so the socket is only reachable by us and the root helper (which
        // bypasses perms). Avoids the predictable world-writable /tmp race.
        let xdg_runtime_dir = std::env::var("XDG_RUNTIME_DIR")
            .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }));
        let runtime_metadata = std::fs::symlink_metadata(&xdg_runtime_dir)
            .map_err(|e| format!("Cannot inspect XDG_RUNTIME_DIR: {e}"))?;
        if !runtime_metadata.file_type().is_dir()
            || runtime_metadata.uid() != unsafe { libc::getuid() }
            || runtime_metadata.mode() & 0o077 != 0
        {
            return Err(
                "XDG_RUNTIME_DIR must be a private directory owned by the current user".to_string(),
            );
        }
        let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
        LISTENER_RUNNING.store(true, Ordering::SeqCst);
        let socket_path = format!(
            "{}/cliphist-dtap-{}.sock",
            xdg_runtime_dir,
            std::process::id()
        );
        let _ = std::fs::remove_file(&socket_path);
        *SOCKET_PATH.lock() = Some((generation, socket_path.clone()));

        let listener = match UnixListener::bind(&socket_path) {
            Ok(listener) => listener,
            Err(e) => {
                cleanup_generation(generation, &socket_path);
                return Err(format!("Failed to create Unix socket: {}", e));
            }
        };
        if let Err(e) =
            std::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o600))
        {
            cleanup_generation(generation, &socket_path);
            return Err(format!("Failed to secure Unix socket: {e}"));
        }
        if let Err(e) = listener.set_nonblocking(true) {
            cleanup_generation(generation, &socket_path);
            return Err(format!("Failed to configure Unix socket: {}", e));
        }

        let helper = match resolve_helper_path() {
            Ok(path) => path,
            Err(error) => {
                cleanup_generation(generation, &socket_path);
                return Err(error);
            }
        };
        let wayland_display =
            std::env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "wayland-0".to_string());

        log::write_log(&format!(
            "Starting pkexec evdev helper: {} (socket: {})",
            helper.display(),
            socket_path
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
            .spawn();
        let child = match child {
            Ok(child) => child,
            Err(e) => {
                cleanup_generation(generation, &socket_path);
                return Err(format!("Failed to spawn pkexec: {}", e));
            }
        };
        log::write_log(&format!("pkexec helper spawned, pid: {}", child.id()));
        *CHILD.lock() = Some((generation, child));

        let spawn_result = std::thread::Builder::new()
            .name("double-tap-socket-listener".to_string())
            .spawn(move || {
                log::write_log("Waiting for evdev helper to connect...");
                let (mut stream, addr) = loop {
                    if GENERATION.load(Ordering::SeqCst) != generation {
                        cleanup_generation(generation, &socket_path);
                        return;
                    }
                    match listener.accept() {
                        Ok(connection) => break connection,
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            std::thread::sleep(std::time::Duration::from_millis(50));
                        }
                        Err(e) => {
                            log::write_log(&format!("Failed to accept helper connection: {}", e));
                            cleanup_generation(generation, &socket_path);
                            return;
                        }
                    }
                };
                if GENERATION.load(Ordering::SeqCst) != generation {
                    cleanup_generation(generation, &socket_path);
                    return;
                }
                match unix_peer_uid(&stream) {
                    Ok(0) => {}
                    Ok(uid) => {
                        log::write_log(&format!(
                            "Rejected evdev helper connection from unexpected UID {uid}"
                        ));
                        cleanup_generation(generation, &socket_path);
                        return;
                    }
                    Err(e) => {
                        log::write_log(&format!("Failed to authenticate evdev helper: {e}"));
                        cleanup_generation(generation, &socket_path);
                        return;
                    }
                }
                log::write_log(&format!("Evdev helper connected from {:?}", addr));
                HELPER_CONNECTED.store(true, Ordering::SeqCst);

                {
                    let mut paste_stream = PASTE_STREAM.lock();
                    *paste_stream = stream.try_clone().ok().map(|s| (generation, s));
                }
                let (ack_tx, ack_rx) = mpsc::channel();
                *PASTE_ACK.lock() = Some((generation, ack_rx));

                let mut buf = [0u8; 1];
                loop {
                    if GENERATION.load(Ordering::SeqCst) != generation {
                        break;
                    }
                    match stream.read(&mut buf) {
                        Ok(1) if buf[0] == b'D' => {
                            if double_tap_wake_allowed() {
                                log::write_log("Double-tap notification from helper!");
                                state::request_window_action();
                            }
                        }
                        Ok(1) if buf[0] == b'S' || buf[0] == b'F' => {
                            let _ = ack_tx.send(buf[0] == b'S');
                        }
                        Ok(1) => log::write_log("Unknown response from evdev helper"),
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
                cleanup_generation(generation, &socket_path);
                log::write_log("Double-tap socket listener stopped");
            });
        if let Err(e) = spawn_result {
            stop_linux_double_tap_listener();
            return Err(format!("Failed to spawn socket listener thread: {}", e));
        }

        Ok(())
    }

    fn unix_peer_uid(stream: &UnixStream) -> std::io::Result<u32> {
        let mut credentials = libc::ucred {
            pid: 0,
            uid: 0,
            gid: 0,
        };
        let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        let result = unsafe {
            libc::getsockopt(
                stream.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                (&mut credentials as *mut libc::ucred).cast(),
                &mut length,
            )
        };
        if result < 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(credentials.uid)
        }
    }

    fn cleanup_generation(generation: u64, socket_path: &str) {
        {
            let mut paste_stream = PASTE_STREAM.lock();
            if matches!(paste_stream.as_ref(), Some((g, _)) if *g == generation) {
                *paste_stream = None;
            }
        }
        {
            let mut ack = PASTE_ACK.lock();
            if matches!(ack.as_ref(), Some((g, _)) if *g == generation) {
                *ack = None;
            }
        }
        {
            let mut child_guard = CHILD.lock();
            if matches!(child_guard.as_ref(), Some((g, _)) if *g == generation) {
                if let Some((_, mut child)) = child_guard.take() {
                    let _ = child.kill();
                    let _ = child.wait();
                }
            }
        }
        {
            let mut path_guard = SOCKET_PATH.lock();
            if matches!(path_guard.as_ref(), Some((g, _)) if *g == generation) {
                *path_guard = None;
            }
        }
        let _ = std::fs::remove_file(socket_path);
        if GENERATION.load(Ordering::SeqCst) == generation {
            HELPER_CONNECTED.store(false, Ordering::SeqCst);
            LISTENER_RUNNING.store(false, Ordering::SeqCst);
        }
    }

    pub fn stop_linux_double_tap_listener() {
        // Invalidate the active listener before touching shared resources so
        // its accept/read loop can no longer publish state.
        GENERATION.fetch_add(1, Ordering::SeqCst);
        LISTENER_RUNNING.store(false, Ordering::SeqCst);
        HELPER_CONNECTED.store(false, Ordering::SeqCst);
        {
            let mut paste_stream = PASTE_STREAM.lock();
            *paste_stream = None;
        }
        *PASTE_ACK.lock() = None;
        let mut child_guard = CHILD.lock();
        if let Some((_, mut child)) = child_guard.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let path = SOCKET_PATH.lock().take();
        if let Some((_, path)) = path {
            let _ = std::fs::remove_file(&path);
        }
    }

    /// Send a paste command to the evdev helper via the bidirectional socket.
    /// The helper (root) performs the uinput/wtype injection and acknowledges
    /// the actual result. Serialize requests so acknowledgements cannot be
    /// consumed by the wrong caller.
    pub fn linux_simulate_paste() -> Result<(), String> {
        let _request = PASTE_REQUEST.lock();
        let generation = {
            let mut guard = PASTE_STREAM.lock();
            let Some((generation, stream)) = guard.as_mut() else {
                return Err("evdev helper 未连接，请先完成 Linux 授权".to_string());
            };
            stream
                .write_all(b"P")
                .map_err(|e| format!("Failed to send paste command to helper: {}", e))?;
            log::write_log("Sent paste command to evdev helper");
            *generation
        };

        let mut ack = PASTE_ACK.lock();
        let Some((ack_generation, receiver)) = ack.as_mut() else {
            return Err("evdev helper 响应通道未连接".to_string());
        };
        if *ack_generation != generation {
            return Err("evdev helper 已重启，请重试".to_string());
        }
        match receiver.recv_timeout(std::time::Duration::from_secs(3)) {
            Ok(true) => Ok(()),
            Ok(false) => Err("系统拒绝了自动粘贴注入".to_string()),
            Err(mpsc::RecvTimeoutError::Timeout) => Err("evdev helper 粘贴超时".to_string()),
            Err(mpsc::RecvTimeoutError::Disconnected) => Err("evdev helper 已断开连接".to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn game_mode_suppresses_double_tap_wake() {
        set_game_mode(true);
        assert!(!double_tap_wake_allowed());
        set_game_mode(false);
        assert!(double_tap_wake_allowed());
    }
}
