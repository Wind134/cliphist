//! Single-instance guard + cross-process "wake the running window" signal.
//!
//! On startup Dart calls [`check`] before `init_app_state`. It tries to take
//! an exclusive advisory lock on a file in the user's data dir:
//!
//!   - **Lock acquired** → we are the first (only) instance. Bind a TCP
//!     listener on `127.0.0.1:0` (OS-assigned port), write `pid:port` into the
//!     lock file, spawn a thread that accepts one-byte "wake" pokes and turns
//!     each into a [`state::request_window_action`] (the same ShowAndRaise
//!     path the hotkey/tray use). Return [`Outcome::FirstInstance`] with
//!     `force_visible` set if `--toggle-window` was on the command line (so a
//!     shortcut binding that launches the app from cold also shows the
//!     window, rather than starting hidden by `silentStart`).
//!
//!   - **Lock held** → another instance is already running. Read its port
//!     from the lock file, connect, send a wake byte, return
//!     [`Outcome::SignalSent`] — Dart then `exit(0)`s. This unifies "user
//!     double-clicked the icon again" with the Wayland `--toggle-window` CLI:
//!     both just poke the existing instance and quit, never opening a second
//!     window / second clipboard poll loop.
//!
//! The lock is an OS advisory file lock (`fs2::FileExt::try_lock_exclusive`)
//! held for the process lifetime by a leaked `File` stored in a static. The
//! kernel releases it automatically when the process dies — even on a crash
//! or `kill -9` — so there is no stale-lock cleanup to do and no PID file to
//! validate. The TCP listener is the wake channel (a Unix-domain socket would
//! need platform-specific code; TCP on loopback is one path for all three OSes
//! and the byte payload is trivial).

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

use fs2::FileExt;

use crate::core::state;
use crate::core::{log, storage};

/// Lock file held alive for the process lifetime. The `File` (with its
/// exclusive lock) must outlive `main`; storing it in a `OnceLock` leaks it
/// deliberately. The TCP listener is owned by the wake-acceptor thread, which
/// keeps it alive for the process lifetime.
static GUARD: OnceLock<File> = OnceLock::new();

/// A wake that arrived before `init_app_state` installed the global state
/// (so `request_window_action` could not yet route it). `init_app_state`
/// drains this via [`drain_pending_wake`] right after `set_state`, closing
/// the cold-start race where a second launch pokes us during our own init.
static PENDING_WAKE: AtomicBool = AtomicBool::new(false);

/// Called from `init_app_state` after the global state is installed. If a
/// wake arrived during our own startup (before state existed), fire the
/// window-action request now and clear the flag.
pub fn drain_pending_wake() {
    if PENDING_WAKE.swap(false, Ordering::SeqCst) {
        log::write_log("single-instance: draining wake that arrived during init");
        state::request_window_action();
    }
}

/// Result of the single-instance check. Dart acts on it before
/// `init_app_state`.
#[derive(Clone, Copy)]
pub enum Outcome {
    /// We own the lock and started the wake listener — proceed to start the
    /// app. `force_visible` is true when `--toggle-window` launched us from
    /// cold (no other instance), so the window should show even if
    /// `silentStart` is on.
    FirstInstance { force_visible: bool },
    /// Another instance is running and we just poked it — Dart must `exit(0)`.
    SignalSent,
}

/// Lock file path: `<data_local_dir>/ClipHist/cliphist.lock`. Created if
/// missing.
fn lock_file_path() -> PathBuf {
    let mut p = storage::app_data_dir();
    if let Err(error) = storage::ensure_private_dir(&p) {
        log::write_log(&error);
    }
    p.push("cliphist.lock");
    p
}

/// Detect `--toggle-window` (or its `--toggle_window` underscore variant) in
/// the process args. Case-insensitive, matches anywhere in the arg list.
fn has_toggle_window_arg() -> bool {
    std::env::args().any(|a| {
        a.eq_ignore_ascii_case("--toggle-window") || a.eq_ignore_ascii_case("--toggle_window")
    })
}

/// Entry point. Returns `FirstInstance` if this process should run the app,
/// or `SignalSent` if it should exit (it already poked the running instance).
/// Never panics — a failure in the single-instance machinery is logged and
/// degrades to "let the app start" so a broken lock never blocks the app.
pub fn check() -> Outcome {
    match try_check() {
        Ok(o) => o,
        Err(e) => {
            log::write_log(&format!("single-instance check failed (proceeding): {}", e));
            // Fail open: start the app rather than block the user.
            Outcome::FirstInstance {
                force_visible: has_toggle_window_arg(),
            }
        }
    }
}

fn try_check() -> std::io::Result<Outcome> {
    let path = lock_file_path();
    let mut file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false) // do NOT truncate on open — that would wipe the port
        // a concurrent second instance is reading, before we even hold the
        // lock. We truncate post-lock via set_len(0) below.
        .open(&path)?;
    storage::ensure_private_file(&path).map_err(std::io::Error::other)?;

    match file.try_lock_exclusive() {
        Ok(()) => {
            // We are the first instance. Bind the wake listener, stamp the
            // lock file with our pid:port, and keep both alive.
            let listener = TcpListener::bind("127.0.0.1:0")?;
            let port = listener.local_addr()?.port();

            // Rewrite the lock file contents atomically enough: truncate +
            // seek + write. Other instances reading concurrently may see a
            // partial write, but they retry and the lock contention is what
            // actually orders them anyway.
            file.set_len(0)?;
            file.seek(SeekFrom::Start(0))?;
            write!(file, "{}:{}", std::process::id(), port)?;
            file.flush()?;
            file.sync_all()?;

            let force_visible = has_toggle_window_arg();
            start_wake_listener(listener)?;

            // Leak the file so the lock outlives this function (process
            // lifetime). The listener is owned by the acceptor thread.
            let _ = GUARD.set(file);
            log::write_log(&format!(
                "single-instance: first instance, wake port {}",
                port
            ));
            Ok(Outcome::FirstInstance { force_visible })
        }
        Err(_) => {
            // Another instance holds the lock. The lock is authoritative:
            // retry briefly while the first process finishes stamping its
            // port, but never start a duplicate clipboard monitor merely
            // because the wake channel is temporarily unavailable.
            drop(file);
            for _ in 0..20 {
                let port = std::fs::read_to_string(&path)
                    .ok()
                    .and_then(|contents| parse_wake_port(&contents));
                if let Some(port) = port {
                    let addr = std::net::SocketAddr::from((std::net::Ipv4Addr::LOCALHOST, port));
                    if let Ok(mut stream) =
                        TcpStream::connect_timeout(&addr, std::time::Duration::from_millis(100))
                    {
                        if stream.write_all(b"wake\n").is_ok() {
                            log::write_log(&format!(
                                "single-instance: poked running instance on port {}",
                                port
                            ));
                            return Ok(Outcome::SignalSent);
                        }
                    }
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            log::write_log(
                "single-instance: lock held but wake channel unavailable; exiting duplicate",
            );
            Ok(Outcome::SignalSent)
        }
    }
}

fn parse_wake_port(contents: &str) -> Option<u16> {
    contents
        .trim()
        .lines()
        .next()
        .and_then(|line| line.split_once(':'))
        .and_then(|(_, port)| port.trim().parse().ok())
}

/// Spawn the wake-acceptor thread. Each accepted connection pokes
/// [`state::request_window_action`]. A wake that arrives before
/// `init_app_state` has installed the global state is retained in
/// [`PENDING_WAKE`] and drained immediately after state initialization.
fn start_wake_listener(listener: TcpListener) -> std::io::Result<()> {
    std::thread::Builder::new()
        .name("single-instance-wake".to_string())
        .spawn(move || {
            // Reuse one buffer; we only care that a byte arrived, not its
            // contents.
            let mut buf = [0u8; 16];
            loop {
                // Accept errors (e.g. transient) are logged and continued.
                match listener.accept() {
                    Ok((mut stream, _addr)) => {
                        let _ = stream.read(&mut buf);
                        // Mark a pending wake in case state isn't installed
                        // yet (cold-start race), then fire immediately if it
                        // is. init_app_state drains the flag after set_state.
                        PENDING_WAKE.store(true, Ordering::SeqCst);
                        state::request_window_action();
                        log::write_log("single-instance: wake received, requesting window action");
                    }
                    Err(e) => {
                        log::write_log(&format!("single-instance: accept error: {}", e));
                        std::thread::sleep(std::time::Duration::from_millis(200));
                    }
                }
            }
        })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::parse_wake_port;

    #[test]
    fn parses_complete_lock_stamp() {
        assert_eq!(parse_wake_port("1234:49152"), Some(49152));
    }

    #[test]
    fn rejects_partial_or_invalid_lock_stamp() {
        assert_eq!(parse_wake_port("1234:"), None);
        assert_eq!(parse_wake_port(""), None);
        assert_eq!(parse_wake_port("1234:not-a-port"), None);
    }
}
