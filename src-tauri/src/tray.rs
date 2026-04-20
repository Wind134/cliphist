use tauri::{
    menu::{MenuBuilder, MenuItemBuilder},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    App, Emitter, Manager,
};

use crate::clipboard::{save_history, ClipboardItem};
use crate::log;

pub fn setup(app: &App) -> Result<(), Box<dyn std::error::Error>> {
    let quit = MenuItemBuilder::with_id("quit", "退出").build(app)?;
    let show = MenuItemBuilder::with_id("show", "显示窗口").build(app)?;
    let clear = MenuItemBuilder::with_id("clear", "清空历史").build(app)?;
    let settings_item = MenuItemBuilder::with_id("settings", "设置").build(app)?;

    let menu = MenuBuilder::new(app)
        .item(&show)
        .item(&settings_item)
        .item(&clear)
        .separator()
        .item(&quit)
        .build()?;

    let icon = app
        .default_window_icon()
        .cloned()
        .ok_or("No default window icon set")?;

    let _tray = TrayIconBuilder::new()
        .icon(icon)
        .menu(&menu)
        .tooltip("ClipHist - 剪贴板历史")
        .on_menu_event(|app, event| match event.id().as_ref() {
            "quit" => {
                log::write_log("Quit menu item clicked, exiting");
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
