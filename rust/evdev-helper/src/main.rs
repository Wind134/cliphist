//! ClipHist Linux evdev double-tap helper.
//!
//! Spike stub: parses the argv contract that the main process passes when it
//! launches this binary via `pkexec`, then prints the parsed args and exits.
//! The real epoll + /dev/input/event* listener + UnixStream 1-byte protocol
//! (`0x01` = double-tap, `P` = paste) is ported from `src-tauri/src/evdev_helper.rs`
//! in M8. This stub exists only to prove the independent binary compiles and
//! links `evdev-rs` + `libc` on Linux.
//!
//! argv contract (kept identical to the existing Tauri version):
//!   cliphist-evdev-helper --evdev-helper --key <Ctrl|Shift|Alt> \
//!                         --socket <path> \
//!                         --wayland-display <wayland-0> \
//!                         --xdg-runtime-dir <path>

use std::process::ExitCode;

fn main() -> ExitCode {
    let mut key = String::new();
    let mut socket = String::new();
    let mut wayland_display = String::new();
    let mut xdg_runtime_dir = String::new();

    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--evdev-helper" => {}
            "--key" => key = args.next().unwrap_or_default(),
            "--socket" => socket = args.next().unwrap_or_default(),
            "--wayland-display" => wayland_display = args.next().unwrap_or_default(),
            "--xdg-runtime-dir" => xdg_runtime_dir = args.next().unwrap_or_default(),
            other => eprintln!("evdev-helper: unknown arg {other}"),
        }
    }

    eprintln!(
        "cliphist-evdev-helper spike stub: key={key} socket={socket} \
         wayland_display={wayland_display} xdg_runtime_dir={xdg_runtime_dir}"
    );
    ExitCode::SUCCESS
}