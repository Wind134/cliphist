//! Automatic 全屏模式: while a fullscreen app (game, video, presentation, F11
//! browser) owns the foreground, double-tap wake is suspended. Windows only;
//! other platforms compile to a no-op.
//!
//! A background thread polls about once per second. A foreground window counts
//! as fullscreen when either
//!   * `SHQueryUserNotificationState` reports an exclusive D3D fullscreen app
//!     or presentation mode, or
//!   * the foreground window's rectangle covers its whole monitor (borderless
//!     fullscreen games, F11 browsers, video players).
//!
//! The desktop / shell windows (Progman, WorkerW, taskbar, task view, start
//! menu), cliphist's own windows, invisible/minimized windows and ordinary
//! maximized windows (captioned + zoomed, e.g. with an auto-hide taskbar) are
//! never treated as fullscreen. The result only drives the runtime
//! `AUTO_FULLSCREEN_ACTIVE` flag; the persisted manual switch is untouched.

/// Plain rectangle so the geometry rule is unit-testable on every platform.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(not(any(test, target_os = "windows")), allow(dead_code))]
pub(crate) struct Rect {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

/// Does `window` cover all of `monitor`? Empty monitor rects never match.
#[cfg_attr(not(any(test, target_os = "windows")), allow(dead_code))]
pub(crate) fn covers_monitor(window: Rect, monitor: Rect) -> bool {
    if monitor.right <= monitor.left || monitor.bottom <= monitor.top {
        return false;
    }
    window.left <= monitor.left
        && window.top <= monitor.top
        && window.right >= monitor.right
        && window.bottom >= monitor.bottom
}

/// Window classes that belong to the desktop or the shell. When one of these
/// is in the foreground the user is not inside a fullscreen app.
#[cfg_attr(not(any(test, target_os = "windows")), allow(dead_code))]
pub(crate) fn is_shell_class(class: &str) -> bool {
    matches!(
        class,
        "Progman"
            | "WorkerW"
            | "Shell_TrayWnd"
            | "Shell_SecondaryTrayWnd"
            | "MultitaskingViewFrame"
            | "XamlExplorerHostIslandWindow"
            | "ForegroundStaging"
            | "Windows.UI.Core.CoreWindow"
            | "LockScreenBackstopFrame"
    )
}

/// Start the detector thread (Windows). No-op elsewhere.
pub fn spawn() {
    #[cfg(target_os = "windows")]
    {
        if let Err(error) = std::thread::Builder::new()
            .name("fullscreen-detect".into())
            .spawn(windows_impl::run)
        {
            crate::core::log::write_log(&format!(
                "Failed to spawn fullscreen-detect thread: {error}"
            ));
        }
    }
}

#[cfg(target_os = "windows")]
mod windows_impl {
    use super::{covers_monitor, is_shell_class, Rect};
    use crate::core::{shortcut_engine, state};
    use std::time::Duration;
    use windows_sys::Win32::Foundation::{HWND, RECT};
    use windows_sys::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST,
    };
    use windows_sys::Win32::UI::Shell::{
        SHQueryUserNotificationState, QUNS_PRESENTATION_MODE, QUNS_RUNNING_D3D_FULL_SCREEN,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetClassNameW, GetForegroundWindow, GetShellWindow, GetWindowLongW, GetWindowRect,
        GetWindowThreadProcessId, IsIconic, IsWindowVisible, IsZoomed, GWL_STYLE, WS_CAPTION,
    };

    const POLL_INTERVAL: Duration = Duration::from_millis(1000);

    pub(super) fn run() {
        let own_pid = std::process::id();
        loop {
            std::thread::sleep(POLL_INTERVAL);
            let enabled =
                state::is_initialized() && state::st().settings.lock().auto_fullscreen_mode;
            let active = enabled && foreground_is_fullscreen(own_pid);
            shortcut_engine::set_auto_fullscreen_active(active);
        }
    }

    fn foreground_is_fullscreen(own_pid: u32) -> bool {
        // SAFETY: plain Win32 queries on a window handle we only read from.
        unsafe {
            let hwnd: HWND = GetForegroundWindow();
            if hwnd.is_null() || hwnd == GetShellWindow() {
                return false;
            }
            let mut pid = 0u32;
            GetWindowThreadProcessId(hwnd, &mut pid);
            if pid == own_pid {
                return false;
            }
            if IsWindowVisible(hwnd) == 0 || IsIconic(hwnd) != 0 {
                return false;
            }
            if is_shell_class(&class_name(hwnd)) {
                return false;
            }

            let mut quns = 0;
            if SHQueryUserNotificationState(&mut quns) >= 0
                && (quns == QUNS_RUNNING_D3D_FULL_SCREEN || quns == QUNS_PRESENTATION_MODE)
            {
                return true;
            }

            // A normal captioned window that is merely maximized (it can cover
            // the monitor when the taskbar auto-hides) is not fullscreen.
            let style = GetWindowLongW(hwnd, GWL_STYLE) as u32;
            if style & WS_CAPTION == WS_CAPTION && IsZoomed(hwnd) != 0 {
                return false;
            }

            let mut wr = RECT::default();
            if GetWindowRect(hwnd, &mut wr) == 0 {
                return false;
            }
            let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            if monitor.is_null() {
                return false;
            }
            let mut mi = MONITORINFO {
                cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                ..Default::default()
            };
            if GetMonitorInfoW(monitor, &mut mi) == 0 {
                return false;
            }
            covers_monitor(to_rect(wr), to_rect(mi.rcMonitor))
        }
    }

    fn to_rect(r: RECT) -> Rect {
        Rect {
            left: r.left,
            top: r.top,
            right: r.right,
            bottom: r.bottom,
        }
    }

    unsafe fn class_name(hwnd: HWND) -> String {
        let mut buf = [0u16; 128];
        let len = GetClassNameW(hwnd, buf.as_mut_ptr(), buf.len() as i32);
        if len <= 0 {
            return String::new();
        }
        String::from_utf16_lossy(&buf[..len as usize])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(left: i32, top: i32, right: i32, bottom: i32) -> Rect {
        Rect {
            left,
            top,
            right,
            bottom,
        }
    }

    #[test]
    fn window_covering_monitor_is_fullscreen() {
        let monitor = r(0, 0, 2560, 1440);
        assert!(covers_monitor(r(0, 0, 2560, 1440), monitor));
        // Slight overhang (borderless windows often extend past the edges).
        assert!(covers_monitor(r(-1, -1, 2561, 1441), monitor));
    }

    #[test]
    fn maximized_or_smaller_window_is_not_fullscreen() {
        let monitor = r(0, 0, 1920, 1080);
        // Maximized above a 48 px taskbar.
        assert!(!covers_monitor(r(-8, -8, 1928, 1040), monitor));
        assert!(!covers_monitor(r(100, 100, 900, 700), monitor));
    }

    #[test]
    fn secondary_monitor_coordinates() {
        let monitor = r(1920, -200, 4480, 1240);
        assert!(covers_monitor(r(1920, -200, 4480, 1240), monitor));
        assert!(!covers_monitor(r(0, 0, 1920, 1080), monitor));
    }

    #[test]
    fn empty_monitor_never_matches() {
        assert!(!covers_monitor(r(0, 0, 10, 10), r(0, 0, 0, 0)));
    }

    #[test]
    fn shell_windows_are_excluded() {
        for class in [
            "Progman",
            "WorkerW",
            "Shell_TrayWnd",
            "Shell_SecondaryTrayWnd",
        ] {
            assert!(is_shell_class(class), "{class}");
        }
        assert!(!is_shell_class("Chrome_WidgetWin_1"));
        assert!(!is_shell_class("UnityWndClass"));
    }
}
