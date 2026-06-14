//! Evdev helper — runs as root via pkexec, listens for double-tap on Linux.
//!
//! This binary mode is invoked by the main process:
//!   pkexec cliphist --evdev-helper --key Ctrl --socket /tmp/cliphist-dtap.sock
//!                     --wayland-display wayland-0 --xdg-runtime-dir /run/user/1000
//!
//! It reads /dev/input/event* (accessible as root), detects double-tap of the
//! configured modifier key, and writes a notification byte to a Unix socket
//! that the main process is listening on.
//!
//! The socket is bidirectional: the helper also reads commands from it.
//!   'P' = perform Ctrl+V paste injection:
//!         1. uinput (kernel-level, works on X11 and most Wayland compositors)
//!         2. wtype (Wayland zwp-virtual-keyboard-v1, fallback for strict compositors)
//!         3. clipboard-only (no-op, user pastes manually)
//!
//! When the socket is closed (main process exits or stops the listener), the
//! helper exits cleanly.

use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::time::Instant;

use evdev_rs::enums::{EventCode, EV_KEY, EV_SYN};
use evdev_rs::uinput::UInputDevice;
use evdev_rs::{Device, InputEvent, ReadFlag, ReadStatus, TimeVal};

/// Persistent uinput device, created once and reused for all paste operations.
/// Must stay alive: transient devices are never registered by libinput/KWin.
static mut PERSISTENT_UINPUT: Option<UInputDevice> = None;

fn create_persistent_uinput() -> Option<UInputDevice> {
    let dev = Device::new()?;
    dev.set_name("ClipHist Virtual Keyboard");
    let _ = dev.enable(&evdev_rs::enums::EventType::EV_KEY);
    for code in [EV_KEY::KEY_LEFTCTRL, EV_KEY::KEY_V].iter() {
        let _ = dev.enable(&EventCode::EV_KEY(code.clone()));
    }
    UInputDevice::create_from_device(&dev).ok()
}

const DOUBLE_TAP_MS: u128 = 300;

struct DoubleTapState {
    last_press: Option<Instant>,
    released: bool,
}

pub fn run(key_name: &str, socket_path: &str, wayland_display: &str, xdg_runtime_dir: &str) -> ! {
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
            eprintln!("[cliphist-helper] Failed to connect to socket {}: {}", socket_path, e);
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
                        eprintln!("[cliphist-helper] Cannot create device from {}: {}", path.display(), e);
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
        unsafe { libc::epoll_ctl(epoll_fd, libc::EPOLL_CTL_ADD, sock_fd, &mut event); }
    }

    for (_dev, fd) in &devices {
        let mut event = libc::epoll_event {
            events: libc::EPOLLIN as u32,
            u64: *fd as u64,
        };
        unsafe { libc::epoll_ctl(epoll_fd, libc::EPOLL_CTL_ADD, *fd, &mut event); }
    }

    let mut state = DoubleTapState { last_press: None, released: true };
    let mut epoll_events: Vec<libc::epoll_event> = Vec::with_capacity(devices.len() + 1);
    let mut cmd_buf = [0u8; 1];

    loop {
        epoll_events.resize(devices.len() + 1, libc::epoll_event { events: 0, u64: 0 });
        let nfds = unsafe {
            libc::epoll_wait(epoll_fd, epoll_events.as_mut_ptr(), epoll_events.len() as i32, 100)
        };

        if nfds < 0 {
            eprintln!("[cliphist-helper] epoll_wait error, exiting");
            break;
        }

        for i in 0..nfds as usize {
            let ready_fd = epoll_events[i].u64 as i32;

            if ready_fd == sock_fd {
                loop {
                    match stream.read(&mut cmd_buf) {
                        Ok(1) if cmd_buf[0] == b'P' => {
                            eprintln!("[cliphist-helper] Paste command received");
                            simulate_paste_injection(&wayland_display, &xdg_runtime_dir);
                        }
                        Ok(0) => {
                            eprintln!("[cliphist-helper] Main process closed socket, exiting");
                            unsafe { libc::close(epoll_fd); }
                            std::process::exit(0);
                        }
                        Ok(_) => {}
                        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                        Err(e) => {
                            eprintln!("[cliphist-helper] Socket read error: {}, exiting", e);
                            unsafe { libc::close(epoll_fd); }
                            std::process::exit(0);
                        }
                    }
                }
                continue;
            }

            for (dev, _fd) in &devices {
                if _fd != &ready_fd { continue; }

                loop {
                    match dev.next_event(ReadFlag::NORMAL) {
                        Ok((ReadStatus::Success, ev)) => {
                            match ev.event_code {
                                EventCode::EV_KEY(kc) => {
                                    if !key_codes_set.contains(&(kc as u32)) { continue; }
                                    if ev.value == 1 {
                                        let now = Instant::now();
                                        if state.released {
                                            if let Some(prev) = state.last_press {
                                                if now.duration_since(prev).as_millis() < DOUBLE_TAP_MS {
                                                    state.last_press = None;
                                                    state.released = false;
                                                    if stream.write_all(&[1]).is_err() {
                                                        unsafe { libc::close(epoll_fd); }
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
                            }
                        }
                        Ok((ReadStatus::Sync, _ev)) => continue,
                        Err(e) => {
                            if e.raw_os_error() == Some(libc::EAGAIN) { break; }
                            break;
                        }
                    }
                }
            }
        }
    }

    for (dev, _) in devices { drop(dev); }
    unsafe { libc::close(epoll_fd); }
    std::process::exit(0);
}

fn simulate_paste_injection(wayland_display: &str, xdg_runtime_dir: &str) {
    // Ensure persistent uinput device is alive (created once, reused forever).
    unsafe {
        if PERSISTENT_UINPUT.is_none() {
            PERSISTENT_UINPUT = create_persistent_uinput();
            if PERSISTENT_UINPUT.is_some() {
                eprintln!("[cliphist-helper] Persistent uinput created, waiting 500ms for libinput...");
                std::thread::sleep(std::time::Duration::from_millis(500));
            }
        }
    }

    if try_uinput_paste() {
        eprintln!("[cliphist-helper] Paste succeeded via uinput");
        return;
    }
    eprintln!("[cliphist-helper] uinput paste failed, trying wtype fallback");

    if try_wtype_paste(wayland_display, xdg_runtime_dir) {
        eprintln!("[cliphist-helper] Paste succeeded via wtype");
        return;
    }
    eprintln!("[cliphist-helper] All paste strategies failed; clipboard is populated, user can paste manually");
}

fn try_uinput_paste() -> bool {
    unsafe {
        match &PERSISTENT_UINPUT {
            Some(uidev) => { inject_ctrl_v_uinput(uidev); true }
            None => false
        }
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
        .arg("-M").arg("ctrl").arg("v")
        .spawn()
    {
        Ok(mut c) => {
            match c.wait() {
                Ok(s) if s.success() => true,
                _ => false,
            }
        }
        Err(_) => false,
    }
}

fn inject_ctrl_v_uinput(uidev: &UInputDevice) {
    use evdev_rs::enums::*;
    let ts = TimeVal::new(0, 0);
    let send = |code: EV_KEY, value: i32| {
        uidev.write_event(&InputEvent {
            time: ts.clone(), event_type: EventType::EV_KEY,
            event_code: EventCode::EV_KEY(code), value,
        }).map_err(|e| eprintln!("[cliphist-helper] uinput write error: {:?}", e)).ok();
    };
    let syn = || {
        uidev.write_event(&InputEvent {
            time: ts.clone(), event_type: EventType::EV_SYN,
            event_code: EventCode::EV_SYN(EV_SYN::SYN_REPORT), value: 0,
        }).map_err(|e| eprintln!("[cliphist-helper] uinput syn error: {:?}", e)).ok();
    };

    send(EV_KEY::KEY_LEFTCTRL, 1); syn();
    std::thread::sleep(std::time::Duration::from_millis(30));
    send(EV_KEY::KEY_V, 1); syn();
    std::thread::sleep(std::time::Duration::from_millis(30));
    send(EV_KEY::KEY_V, 0); syn();
    std::thread::sleep(std::time::Duration::from_millis(30));
    send(EV_KEY::KEY_LEFTCTRL, 0); syn();
    std::thread::sleep(std::time::Duration::from_millis(30));
}
