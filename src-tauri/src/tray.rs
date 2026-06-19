use tauri::{
    menu::{MenuBuilder, MenuItemBuilder},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    App, Emitter, Manager,
};

use crate::clipboard::{save_history, ClipboardItem};
use crate::log;

pub fn setup(app: &App) -> Result<(), Box<dyn std::error::Error>> {
    let quit = MenuItemBuilder::with_id("quit", "退出").build(app)?;
    let restart = MenuItemBuilder::with_id("restart", "重启应用").build(app)?;
    let show = MenuItemBuilder::with_id("show", "显示窗口").build(app)?;
    let clear = MenuItemBuilder::with_id("clear", "清空历史").build(app)?;
    let settings_item = MenuItemBuilder::with_id("settings", "设置").build(app)?;

    let menu = MenuBuilder::new(app)
        .item(&show)
        .item(&settings_item)
        .item(&clear)
        .separator()
        .item(&restart)
        .item(&quit)
        .build()?;

    // Decode the tray icon from embeded PNG using the `image` crate directly,
    // then wrap it in a tauri Image. This avoids tauri-build caching issues.
    let img = image::load_from_memory(include_bytes!("../icons/32x32.png"))
        .map_err(|e| format!("Failed to decode tray icon: {}", e))?
        .into_rgba8();
    let (width, height) = img.dimensions();
    let rgba = img.into_raw();
    let icon = tauri::image::Image::new(&rgba, width, height);

    let _tray = TrayIconBuilder::new()
        .icon(icon)
        .menu(&menu)
        .tooltip("ClipHist - 剪贴板历史")
        .on_menu_event(|app, event| match event.id().as_ref() {
            "quit" => {
                log::write_log("Quit menu item clicked, exiting");
                app.exit(0);
            }
            "restart" => {
                log::write_log("Restart menu item clicked, restarting");
                match std::env::current_exe() {
                    Ok(exe) => {
                        log::write_log(&format!("Spawning new process: {:?}", exe));
                        if let Err(e) = std::process::Command::new(&exe).spawn() {
                            log::write_log(&format!("Failed to spawn new process: {}", e));
                        }
                    }
                    Err(e) => {
                        log::write_log(&format!("Failed to get current exe path: {}", e));
                    }
                }
                app.exit(0);
            }
            "show" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            "settings" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                    let _ = window.emit("open-settings", ());
                }
            }
            "clear" => {
                let state = app.state::<crate::state::AppState>();
                let mut history = state.history.lock();
                history.clear();
                save_history(&history);
                drop(history);
                let _ = app.emit("clipboard-changed", Vec::<ClipboardItem>::new());
                log::write_log("History cleared from tray menu");
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let app = tray.app_handle();
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
        })
        .build(app)?;

    Ok(())
}
