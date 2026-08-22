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
//! It is a standalone binary with its own argument parsing and inline
//! `DoubleTapState`, keeping privileged input access outside the main process.

use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Component, Path, PathBuf};
use std::time::Instant;

use evdev_rs::enums::{EventCode, EV_KEY, EV_SYN};
use evdev_rs::uinput::UInputDevice;
use evdev_rs::{Device, InputEvent, ReadFlag, ReadStatus, TimeVal};

struct DoubleTapState {
    last_press: Option<Instant>,
    released: bool,
}

const DOUBLE_TAP_MS: u128 = 300;

struct Invocation {
    uid: u32,
    gid: u32,
    socket_path: PathBuf,
    wayland_display: String,
    runtime_dir: PathBuf,
}

struct InputDevice {
    device: Device,
    fd: i32,
    path: PathBuf,
}

fn create_persistent_uinput() -> Option<UInputDevice> {
    let dev = Device::new()?;
    dev.set_name("ClipHist Virtual Keyboard");
    dev.enable(&evdev_rs::enums::EventType::EV_KEY).ok()?;
    for code in [EV_KEY::KEY_LEFTCTRL, EV_KEY::KEY_V].iter() {
        dev.enable(&EventCode::EV_KEY(code.clone())).ok()?;
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

    if key_name.is_empty() || socket_path.is_empty() || xdg_runtime_dir.is_empty() {
        eprintln!("[cliphist-helper] --key and --socket are required");
        std::process::exit(1);
    }

    let invocation = validate_invocation(&socket_path, &wayland_display, &xdg_runtime_dir)
        .unwrap_or_else(|error| {
            eprintln!("[cliphist-helper] Refusing unsafe invocation: {error}");
            std::process::exit(1);
        });
    run(&key_name, invocation);
}

fn validate_invocation(
    socket_path: &str,
    wayland_display: &str,
    runtime_dir: &str,
) -> Result<Invocation, String> {
    if unsafe { libc::geteuid() } != 0 {
        return Err("helper must be launched by pkexec as root".to_string());
    }
    // The helper needs effective root for evdev/uinput, but never needs any
    // supplementary groups. Clear them once so the unprivileged `wtype`
    // fallback cannot inherit ambient groups from pkexec's root process.
    if unsafe { libc::setgroups(0, std::ptr::null()) } != 0 {
        return Err(format!(
            "cannot clear supplementary groups: {}",
            std::io::Error::last_os_error()
        ));
    }
    let uid = std::env::var("PKEXEC_UID")
        .map_err(|_| "PKEXEC_UID is missing".to_string())?
        .parse::<u32>()
        .map_err(|_| "PKEXEC_UID is invalid".to_string())?;
    if uid == 0 {
        return Err("refusing a root desktop-session identity".to_string());
    }

    let runtime_dir = PathBuf::from(runtime_dir);
    if !runtime_dir.is_absolute() {
        return Err("XDG runtime directory must be absolute".to_string());
    }
    let runtime_meta = fs::symlink_metadata(&runtime_dir)
        .map_err(|error| format!("cannot inspect runtime directory: {error}"))?;
    if !runtime_meta.file_type().is_dir()
        || runtime_meta.uid() != uid
        || runtime_meta.mode() & 0o077 != 0
    {
        return Err(
            "runtime directory must be a private directory owned by PKEXEC_UID".to_string(),
        );
    }
    let runtime_dir = fs::canonicalize(runtime_dir)
        .map_err(|error| format!("cannot canonicalize runtime directory: {error}"))?;

    let socket_path = PathBuf::from(socket_path);
    let socket_name = socket_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| "socket name is invalid".to_string())?;
    if !valid_socket_name(socket_name) {
        return Err("socket name is outside the ClipHist namespace".to_string());
    }
    let socket_parent = socket_path
        .parent()
        .and_then(|parent| fs::canonicalize(parent).ok())
        .ok_or_else(|| "socket parent is invalid".to_string())?;
    if socket_parent != runtime_dir {
        return Err("socket must be directly inside the validated runtime directory".to_string());
    }
    let socket_meta = fs::symlink_metadata(&socket_path)
        .map_err(|error| format!("cannot inspect socket: {error}"))?;
    if !socket_meta.file_type().is_socket() || socket_meta.uid() != uid {
        return Err("socket must be a Unix socket owned by PKEXEC_UID".to_string());
    }

    if !wayland_display.is_empty() && !valid_wayland_display(wayland_display) {
        return Err("WAYLAND_DISPLAY must be a single file name".to_string());
    }

    Ok(Invocation {
        uid,
        gid: runtime_meta.gid(),
        socket_path,
        wayland_display: wayland_display.to_string(),
        runtime_dir,
    })
}

fn valid_socket_name(name: &str) -> bool {
    const PREFIX: &str = "cliphist-dtap-";
    const SUFFIX: &str = ".sock";
    if !name.starts_with(PREFIX) || !name.ends_with(SUFFIX) {
        return false;
    }
    let identity = &name[PREFIX.len()..name.len() - SUFFIX.len()];
    !identity.is_empty() && identity.chars().all(|character| character.is_ascii_digit())
}

fn valid_wayland_display(display: &str) -> bool {
    let mut components = Path::new(display).components();
    matches!(components.next(), Some(Component::Normal(_))) && components.next().is_none()
}

fn run(key_name: &str, invocation: Invocation) -> ! {
    eprintln!("[cliphist-helper] Starting evdev helper");
    eprintln!("[cliphist-helper] Key: {}", key_name);
    eprintln!(
        "[cliphist-helper] Socket: {}",
        invocation.socket_path.display()
    );

    let wayland_display = invocation.wayland_display;
    let xdg_runtime_dir = invocation.runtime_dir;

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

    let mut stream = match UnixStream::connect(&invocation.socket_path) {
        Ok(s) => {
            eprintln!("[cliphist-helper] Connected to main process");
            s
        }
        Err(e) => {
            eprintln!(
                "[cliphist-helper] Failed to connect to socket {}: {}",
                invocation.socket_path.display(),
                e
            );
            std::process::exit(1);
        }
    };

    match unix_peer_uid(&stream) {
        Ok(peer_uid) if peer_uid == invocation.uid => {}
        Ok(peer_uid) => {
            eprintln!("[cliphist-helper] Socket peer UID mismatch: {peer_uid}");
            std::process::exit(1);
        }
        Err(error) => {
            eprintln!("[cliphist-helper] Cannot authenticate socket peer: {error}");
            std::process::exit(1);
        }
    }

    let sock_fd = stream.as_raw_fd();
    if let Err(error) = set_nonblocking(sock_fd) {
        eprintln!("[cliphist-helper] Cannot configure socket: {error}");
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
        if unsafe { libc::epoll_ctl(epoll_fd, libc::EPOLL_CTL_ADD, sock_fd, &mut event) } < 0 {
            eprintln!(
                "[cliphist-helper] Failed to add socket to epoll: {}",
                std::io::Error::last_os_error()
            );
            std::process::exit(1);
        }
    }

    let mut devices = Vec::new();
    discover_input_devices(&mut devices, epoll_fd, &key_codes);
    if devices.is_empty() {
        eprintln!("[cliphist-helper] No keyboard devices found; waiting for hotplug");
    }

    let mut state = DoubleTapState {
        last_press: None,
        released: true,
    };
    let mut persistent_uinput: Option<UInputDevice> = None;
    let mut epoll_events: Vec<libc::epoll_event> = Vec::with_capacity(devices.len() + 1);
    let mut cmd_buf = [0u8; 1];
    let mut last_device_scan = Instant::now();

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
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            eprintln!("[cliphist-helper] epoll_wait error: {error}");
            break;
        }

        let mut dead_fds = std::collections::HashSet::new();
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
                                invocation.uid,
                                invocation.gid,
                            );
                            if stream
                                .write_all(if pasted { b"S" } else { b"F" })
                                .and_then(|()| stream.flush())
                                .is_err()
                            {
                                eprintln!("[cliphist-helper] Failed to acknowledge paste result");
                                unsafe {
                                    libc::close(epoll_fd);
                                }
                                std::process::exit(0);
                            }
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

            for input in &devices {
                if input.fd != ready_fd {
                    continue;
                }

                loop {
                    match input.device.next_event(ReadFlag::NORMAL) {
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
                                                if stream.flush().is_err() {
                                                    unsafe {
                                                        libc::close(epoll_fd);
                                                    }
                                                    std::process::exit(0);
                                                }
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
                            EventCode::EV_SYN(EV_SYN::SYN_DROPPED) => {
                                state.last_press = None;
                                state.released = true;
                            }
                            _ => {}
                        },
                        Ok((ReadStatus::Sync, _ev)) => {
                            // Discard the state-delta stream after SYN_DROPPED
                            // and reset the gesture state. Treating sync events
                            // as real presses can create a phantom double tap.
                            state.last_press = None;
                            state.released = true;
                            loop {
                                match input.device.next_event(ReadFlag::SYNC) {
                                    Ok((ReadStatus::Sync, _)) => {}
                                    Ok((ReadStatus::Success, _)) => break,
                                    Err(error) if error.raw_os_error() == Some(libc::EAGAIN) => {
                                        break;
                                    }
                                    Err(_) => {
                                        dead_fds.insert(ready_fd);
                                        break;
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            if e.raw_os_error() == Some(libc::EAGAIN) {
                                break;
                            }
                            dead_fds.insert(ready_fd);
                            break;
                        }
                    }
                }
            }
        }

        if !dead_fds.is_empty() {
            devices.retain(|input| {
                if dead_fds.contains(&input.fd) {
                    unsafe {
                        libc::epoll_ctl(
                            epoll_fd,
                            libc::EPOLL_CTL_DEL,
                            input.fd,
                            std::ptr::null_mut(),
                        );
                    }
                    eprintln!(
                        "[cliphist-helper] Input device disconnected: {}",
                        input.path.display()
                    );
                    false
                } else {
                    true
                }
            });
        }
        if last_device_scan.elapsed() >= std::time::Duration::from_secs(2) {
            discover_input_devices(&mut devices, epoll_fd, &key_codes);
            last_device_scan = Instant::now();
        }
    }

    for input in devices {
        drop(input.device);
    }
    unsafe {
        libc::close(epoll_fd);
    }
    std::process::exit(0);
}

fn discover_input_devices(devices: &mut Vec<InputDevice>, epoll_fd: i32, keys: &[EV_KEY]) {
    let known = devices
        .iter()
        .map(|input| input.path.clone())
        .collect::<std::collections::HashSet<_>>();
    let Ok(entries) = fs::read_dir("/dev/input") else {
        eprintln!("[cliphist-helper] Cannot read /dev/input");
        return;
    };

    for entry in entries.flatten() {
        let path = entry.path();
        let is_event = entry
            .file_name()
            .to_str()
            .is_some_and(|name| name.starts_with("event"));
        if !is_event || known.contains(&path) {
            continue;
        }
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if !metadata.file_type().is_char_device() {
            continue;
        }
        let Ok(file) = File::open(&path) else {
            continue;
        };
        let fd = file.as_raw_fd();
        let Ok(device) = Device::new_from_fd(file) else {
            continue;
        };
        if !keys
            .iter()
            .any(|key| device.has(&EventCode::EV_KEY(key.clone())))
        {
            continue;
        }
        if let Err(error) = set_nonblocking(fd) {
            eprintln!(
                "[cliphist-helper] Cannot configure {}: {error}",
                path.display()
            );
            continue;
        }
        let mut event = libc::epoll_event {
            events: (libc::EPOLLIN | libc::EPOLLERR | libc::EPOLLHUP) as u32,
            u64: fd as u64,
        };
        if unsafe { libc::epoll_ctl(epoll_fd, libc::EPOLL_CTL_ADD, fd, &mut event) } < 0 {
            eprintln!(
                "[cliphist-helper] Cannot monitor {}: {}",
                path.display(),
                std::io::Error::last_os_error()
            );
            continue;
        }
        eprintln!("[cliphist-helper] Monitoring {}", path.display());
        devices.push(InputDevice { device, fd, path });
    }
}

fn simulate_paste_injection(
    uinput: &mut Option<UInputDevice>,
    wayland_display: &str,
    xdg_runtime_dir: &Path,
    uid: u32,
    gid: u32,
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

    if try_wtype_paste(wayland_display, xdg_runtime_dir, uid, gid) {
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

fn try_wtype_paste(wayland_display: &str, xdg_runtime_dir: &Path, uid: u32, gid: u32) -> bool {
    use std::os::unix::process::CommandExt;

    if wayland_display.is_empty() {
        return false;
    }
    let wayland_socket = xdg_runtime_dir.join(wayland_display);
    let Ok(metadata) = fs::symlink_metadata(&wayland_socket) else {
        return false;
    };
    if !metadata.file_type().is_socket() || metadata.uid() != uid {
        return false;
    }
    let executable = ["/usr/bin/wtype", "/bin/wtype"]
        .into_iter()
        .find(|path| Path::new(path).is_file());
    let Some(executable) = executable else {
        return false;
    };
    match std::process::Command::new(executable)
        .env_clear()
        .env("WAYLAND_DISPLAY", wayland_display)
        .env("XDG_RUNTIME_DIR", xdg_runtime_dir)
        .uid(uid)
        .gid(gid)
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

fn set_nonblocking(fd: i32) -> std::io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL, 0) };
    if flags < 0 {
        return Err(std::io::Error::last_os_error());
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(std::io::Error::last_os_error());
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

#[cfg(test)]
mod tests {
    use super::{valid_socket_name, valid_wayland_display};

    #[test]
    fn validates_names_crossing_the_privilege_boundary() {
        assert!(valid_socket_name("cliphist-dtap-1234.sock"));
        assert!(!valid_socket_name("cliphist-dtap-.sock"));
        assert!(!valid_socket_name("other-1234.sock"));
        assert!(valid_wayland_display("wayland-0"));
        assert!(!valid_wayland_display("../wayland-0"));
        assert!(!valid_wayland_display("nested/wayland-0"));
    }
}
