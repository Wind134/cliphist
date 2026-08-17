//! Privileged evdev helper for ClipHist — runs as root via pkexec.
//!
//! Invoked by the main process as:
//!   cliphist-evdev-helper --key Ctrl --socket /run/user/1000/cliphist-dtap-<pid>.sock \
//!     --wayland-display wayland-0 --xdg-runtime-dir /run/user/1000
//!
//! It reads /dev/input/event* (accessible as root), detects a double-tap of
//! the configured modifier key, and writes `b'D'` to the Unix socket the main
//! process is listening on. The socket is bidirectional: `b'P'` triggers
//! Ctrl+V paste injection via uinput (with a `wtype` fallback), followed by a
//! `b'S'`/`b'F'` success acknowledgement. When the socket closes, the helper
//! exits cleanly.
//!
//! Ported verbatim from `src-tauri/src/evdev_helper.rs`; the only change is
//! standing alone (own arg parsing, inline `DoubleTapState`) instead of
//! re-entering the main binary behind a `--evdev-helper` flag (plan 3.1).

use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::time::Instant;

use evdev_rs::enums::{EventCode, EV_KEY, EV_SYN};
use evdev_rs::uinput::UInputDevice;
use evdev_rs::{Device, InputEvent, ReadFlag, ReadStatus, TimeVal};

struct DoubleTapState {
    last_press: Option<Instant>,
    released: bool,
}

const DOUBLE_TAP_MS: u128 = 300;

fn create_persistent_uinput() -> Option<UInputDevice> {
    let dev = Device::new()?;
    dev.set_name("ClipHist Virtual Keyboard");
    let _ = dev.enable(&evdev_rs::enums::EventType::EV_KEY);
    for code in [EV_KEY::KEY_LEFTCTRL, EV_KEY::KEY_V].iter() {
        let _ = dev.enable(&EventCode::EV_KEY(code.clone()));
    }
    UInputDevice::create_from_device(&dev).ok()
}

fn main() {
    let mut key_name = String::new();
    let mut socket_path = String::new();
    let mut wayland_display = String::new();
    let mut xdg_runtime_dir = String::new();

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--key" => key_name = args.next().unwrap_or_default(),
            "--socket" => socket_path = args.next().unwrap_or_default(),
            "--wayland-display" => wayland_display = args.next().unwrap_or_default(),
            "--xdg-runtime-dir" => xdg_runtime_dir = args.next().unwrap_or_default(),
            "-h" | "--help" => {
                eprintln!(
                    "Usage: cliphist-evdev-helper --key <Ctrl|Shift|Alt> --socket <path> \
                     --wayland-display <display> --xdg-runtime-dir <dir>"
                );
                std::process::exit(0);
            }
            _ => {}
        }
    }

    if key_name.is_empty() || socket_path.is_empty() {
        eprintln!("[cliphist-helper] --key and --socket are required");
        std::process::exit(1);
    }

    run(&key_name, &socket_path, &wayland_display, &xdg_runtime_dir);
}

fn run(key_name: &str, socket_path: &str, wayland_display: &str, xdg_runtime_dir: &str) -> ! {
    eprintln!("[cliphist-helper] Starting evdev helper");
    eprintln!("[cliphist-helper] Key: {}", key_name);
    eprintln!("[cliphist-helper] Socket: {}", socket_path);

    let wayland_display = wayland_display.to_string();
    let xdg_runtime_dir = xdg_runtime_dir.to_string();

    let key_codes: Vec<EV_KEY> = match key_name {
        "Ctrl" => vec![EV_KEY::KEY_LEFTCTRL, EV_KEY::KEY_RIGHTCTRL],
        "Shift" => vec![EV_KEY::KEY_LEFTSHIFT, EV_KEY::KEY_RIGHTSHIFT],
        "Alt" => vec![EV_KEY::KEY_LEFTALT, EV_KEY::KEY_RIGHTALT],
        other => {
            eprintln!("[cliphist-helper] Unsupported key: {}", other);
            std::process::exit(1);
        }
    };
    let key_codes_set: std::collections::HashSet<u32> =
        key_codes.iter().map(|k| k.clone() as u32).collect();

    let mut stream = match UnixStream::connect(socket_path) {
        Ok(s) => {
            eprintln!("[cliphist-helper] Connected to main process");
            s
        }
        Err(e) => {
            eprintln!(
                "[cliphist-helper] Failed to connect to socket {}: {}",
                socket_path, e
            );
            std::process::exit(1);
        }
    };

    let sock_fd = stream.as_raw_fd();
    unsafe {
        let flags = libc::fcntl(sock_fd, libc::F_GETFL, 0);
        libc::fcntl(sock_fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }

    let mut devices: Vec<(Device, i32)> = Vec::new();
    let entries = match fs::read_dir("/dev/input") {
        Ok(e) => e,
        Err(_) => {
            eprintln!("[cliphist-helper] Cannot read /dev/input");
            std::process::exit(1);
        }
    };

    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.starts_with("event") {
            continue;
        }
        let path = entry.path();
        match File::open(&path) {
            Ok(file) => {
                let fd = file.as_raw_fd();
                match Device::new_from_fd(file) {
                    Ok(dev) => {
                        if !dev.has(&evdev_rs::enums::EventType::EV_KEY) {
                            continue;
                        }
                        unsafe {
                            let flags = libc::fcntl(fd, libc::F_GETFL, 0);
                            libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
                        }
                        devices.push((dev, fd));
                    }
                    Err(e) => {
                        eprintln!(
                            "[cliphist-helper] Cannot create device from {}: {}",
                            path.display(),
                            e
                        );
                    }
                }
            }
            Err(e) => {
                eprintln!("[cliphist-helper] Cannot open {}: {}", path.display(), e);
            }
        }
    }

    if devices.is_empty() {
        eprintln!("[cliphist-helper] No keyboard devices found.");
        std::process::exit(1);
    }

    let epoll_fd = unsafe { libc::epoll_create1(0) };
    if epoll_fd < 0 {
        eprintln!("[cliphist-helper] Failed to create epoll fd");
        std::process::exit(1);
    }

    {
        let mut event = libc::epoll_event {
            events: libc::EPOLLIN as u32,
            u64: sock_fd as u64,
        };
        unsafe {
            libc::epoll_ctl(epoll_fd, libc::EPOLL_CTL_ADD, sock_fd, &mut event);
        }
    }

    for (_dev, fd) in &devices {
        let mut event = libc::epoll_event {
            events: libc::EPOLLIN as u32,
            u64: *fd as u64,
        };
        unsafe {
            libc::epoll_ctl(epoll_fd, libc::EPOLL_CTL_ADD, *fd, &mut event);
        }
    }

    let mut state = DoubleTapState {
        last_press: None,
        released: true,
    };
    let mut persistent_uinput: Option<UInputDevice> = None;
    let mut epoll_events: Vec<libc::epoll_event> = Vec::with_capacity(devices.len() + 1);
    let mut cmd_buf = [0u8; 1];

    loop {
        epoll_events.resize(devices.len() + 1, libc::epoll_event { events: 0, u64: 0 });
        let nfds = unsafe {
            libc::epoll_wait(
                epoll_fd,
                epoll_events.as_mut_ptr(),
                epoll_events.len() as i32,
                100,
            )
        };

        if nfds < 0 {
            eprintln!("[cliphist-helper] epoll_wait error, exiting");
            break;
        }

        for event in epoll_events.iter().take(nfds as usize) {
            let ready_fd = event.u64 as i32;

            if ready_fd == sock_fd {
                loop {
                    match stream.read(&mut cmd_buf) {
                        Ok(1) if cmd_buf[0] == b'P' => {
                            eprintln!("[cliphist-helper] Paste command received");
                            let pasted = simulate_paste_injection(
                                &mut persistent_uinput,
                                &wayland_display,
                                &xdg_runtime_dir,
                            );
                            let _ = stream.write_all(if pasted { b"S" } else { b"F" });
                            let _ = stream.flush();
                        }
                        Ok(0) => {
                            eprintln!("[cliphist-helper] Main process closed socket, exiting");
                            unsafe {
                                libc::close(epoll_fd);
                            }
                            std::process::exit(0);
                        }
                        Ok(_) => {}
                        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                        Err(e) => {
                            eprintln!("[cliphist-helper] Socket read error: {}, exiting", e);
                            unsafe {
                                libc::close(epoll_fd);
                            }
                            std::process::exit(0);
                        }
                    }
                }
                continue;
            }

            for (dev, dev_fd) in &devices {
                if dev_fd != &ready_fd {
                    continue;
                }

                loop {
                    match dev.next_event(ReadFlag::NORMAL) {
                        Ok((ReadStatus::Success, ev)) => match ev.event_code {
                            EventCode::EV_KEY(kc) => {
                                if !key_codes_set.contains(&(kc as u32)) {
                                    continue;
                                }
                                if ev.value == 1 {
                                    let now = Instant::now();
                                    if state.released {
                                        if let Some(prev) = state.last_press {
                                            if now.duration_since(prev).as_millis() < DOUBLE_TAP_MS
                                            {
                                                state.last_press = None;
                                                state.released = false;
                                                if stream.write_all(b"D").is_err() {
                                                    unsafe {
                                                        libc::close(epoll_fd);
                                                    }
                                                    std::process::exit(0);
                                                }
                                                let _ = stream.flush();
                                                continue;
                                            }
                                        }
                                        state.last_press = Some(now);
                                        state.released = false;
                                    }
                                } else if ev.value == 0 {
                                    state.released = true;
                                }
                            }
                            EventCode::EV_SYN(EV_SYN::SYN_DROPPED) => {}
                            _ => {}
                        },
                        Ok((ReadStatus::Sync, _ev)) => continue,
                        Err(e) => {
                            if e.raw_os_error() == Some(libc::EAGAIN) {
                                break;
                            }
                            break;
                        }
                    }
                }
            }
        }
    }

    for (dev, _) in devices {
        drop(dev);
    }
    unsafe {
        libc::close(epoll_fd);
    }
    std::process::exit(0);
}

fn simulate_paste_injection(
    uinput: &mut Option<UInputDevice>,
    wayland_display: &str,
    xdg_runtime_dir: &str,
) -> bool {
    if uinput.is_none() {
        *uinput = create_persistent_uinput();
        if uinput.is_some() {
            eprintln!("[cliphist-helper] Persistent uinput created, waiting 500ms for libinput...");
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
    }

    if try_uinput_paste(uinput) {
        eprintln!("[cliphist-helper] Paste succeeded via uinput");
        return true;
    }
    eprintln!("[cliphist-helper] uinput paste failed, trying wtype fallback");

    if try_wtype_paste(wayland_display, xdg_runtime_dir) {
        eprintln!("[cliphist-helper] Paste succeeded via wtype");
        return true;
    }
    eprintln!(
        "[cliphist-helper] All paste strategies failed; clipboard is populated, user can paste manually"
    );
    false
}

fn try_uinput_paste(uinput: &mut Option<UInputDevice>) -> bool {
    match uinput {
        Some(uidev) => inject_ctrl_v_uinput(uidev),
        None => false,
    }
}

fn try_wtype_paste(wayland_display: &str, xdg_runtime_dir: &str) -> bool {
    let wayland_socket = format!("{}/{}", xdg_runtime_dir, wayland_display);
    if !std::path::Path::new(&wayland_socket).exists() {
        return false;
    }
    match std::process::Command::new("wtype")
        .env("WAYLAND_DISPLAY", wayland_display)
        .env("XDG_RUNTIME_DIR", xdg_runtime_dir)
        .arg("-M")
        .arg("ctrl")
        .arg("v")
        .spawn()
    {
        Ok(mut child) => {
            let deadline = Instant::now() + std::time::Duration::from_secs(1);
            loop {
                match child.try_wait() {
                    Ok(Some(status)) => return status.success(),
                    Ok(None) if Instant::now() < deadline => {
                        std::thread::sleep(std::time::Duration::from_millis(20));
                    }
                    Ok(None) => {
                        let _ = child.kill();
                        let _ = child.wait();
                        return false;
                    }
                    Err(_) => return false,
                }
            }
        }
        Err(_) => false,
    }
}

fn inject_ctrl_v_uinput(uidev: &UInputDevice) -> bool {
    use evdev_rs::enums::*;
    let ts = TimeVal::new(0, 0);
    let send = |code: EV_KEY, value: i32| match uidev.write_event(&InputEvent {
        time: ts.clone(),
        event_type: EventType::EV_KEY,
        event_code: EventCode::EV_KEY(code),
        value,
    }) {
        Ok(()) => true,
        Err(e) => {
            eprintln!("[cliphist-helper] uinput write error: {:?}", e);
            false
        }
    };
    let syn = || match uidev.write_event(&InputEvent {
        time: ts.clone(),
        event_type: EventType::EV_SYN,
        event_code: EventCode::EV_SYN(EV_SYN::SYN_REPORT),
        value: 0,
    }) {
        Ok(()) => true,
        Err(e) => {
            eprintln!("[cliphist-helper] uinput syn error: {:?}", e);
            false
        }
    };

    let mut success = send(EV_KEY::KEY_LEFTCTRL, 1) & syn();
    std::thread::sleep(std::time::Duration::from_millis(30));
    success &= send(EV_KEY::KEY_V, 1) & syn();
    std::thread::sleep(std::time::Duration::from_millis(30));
    success &= send(EV_KEY::KEY_V, 0) & syn();
    std::thread::sleep(std::time::Duration::from_millis(30));
    // Always attempt releases even after an earlier write failure so a
    // partially delivered sequence cannot leave Ctrl/V logically held.
    success &= send(EV_KEY::KEY_LEFTCTRL, 0) & syn();
    std::thread::sleep(std::time::Duration::from_millis(30));
    success
}
