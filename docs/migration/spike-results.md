# Spike 结果 — Rust+Flutter 迁移关键路径验证

日期：2026-08-15 · 分支：`feat/flutter-rust-migration` · 环境：WSL2 + WSLg, Flutter 3.44.9, Rust 1.94.1, FRB 2.12.0

一键复现：`./flutter/spike.sh`（编译门槛）。运行时冒烟：`cd flutter && DISPLAY=:0 ./build/linux/x64/debug/bundle/cliphist`。

## 三项 go/no-go 结果

### A — FRB 双向 + StreamSink 事件流 ✅
- 编译：`flutter build linux` 经 Cargokit 同时编译 Dart 与 `rust_lib_cliphist` crate 通过。
- 运行时：`streamClipboardChanged()` 在 Rust 端每 500ms `sink.add("tick N")`，Dart 监听器 5 秒内收到 8 个事件，首个远在 1s 内 → 流交付达标。
- round-trip 函数 `getHistory()`（sync）/ `copyToClipboard`（async, 含错误路径）/ `updateSettings`（async）编译 + 绑定无误（FRB 通道由 init + 流已证明可用；按钮点击的体感确认留 GUI 手测）。
- 踩坑修正：`StreamSink` 不在 `flutter_rust_bridge` crate 根，而是 `frb_generated!` 宏在**本 crate 的 `frb_generated` 模块**里生成的 `pub struct` → 正确导入 `use crate::frb_generated::StreamSink;`。

### B — window_manager + tray_manager（Linux）✅
- 编译：三插件（window_manager 0.5.2 / tray_manager 0.5.3 / screen_retriever）链接通过。
- 运行时：窗口创建成功（进程稳）；tray `setIcon`+`setTitle`+`setContextMenu` 全部成功，无 `MissingPluginException`。
- 踩坑修正 1：tray_manager 0.5.3 Linux 端**只实现** `destroy/setIcon/setTitle/setContextMenu`，无 `setToolTip`/`setIconPosition`/`popUpContextMenu` → spike 改用 `setTitle`，去掉 `setToolTip`。
- 踩坑修正 2：tray_manager C++ 插件用新版 ayatana 已废弃的 `app_indicator_new`，被 `-Werror` 当错误 → `linux/CMakeLists.txt` 加 `add_compile_options(-Wno-error=deprecated-declarations)` 降为警告。
- 踩坑修正 3：window_manager 0.5.2 的聚焦方法是 `focus()`，不是 `setFocus()`。
- 残留：`libayatana-appindicator is deprecated`（上游）与 `gtk_widget_get_scale_factor: GTK_IS_WIDGET`（Gtk 噪声）两条警告，不崩、不影响功能。
- 待手测：window dance（alwaysOnTop→hide→30ms→show→focus→500ms→alwaysOnTop(false)）时序、托盘菜单 4 项点击回调到 FRB、左键托盘切换窗口。

### C — evdev-helper 独立 binary ✅
- 编译：`cargo build -p cliphist-evdev-helper` 出独立 binary（~4MB debug），链接 `evdev-rs 0.4` + `libc`。
- 当前是 stub：解析 `--evdev-helper --key --socket --wayland-display --xdg-runtime-dir` argv 契约后打印退出。真实 epoll + `/dev/input/event*` + UnixStream 1 字节协议（`0x01`/`'P'`）在 M8 从 `src-tauri/src/evdev_helper.rs` 移植。
- 待真机手测：`pkexec cliphist-evdev-helper ...` 拉起、polkit 授权、socket 双向、双击 Ctrl 触发。

## 结论：go。进入 M2（Rust 核心全量移植）。

## 已知后续动作（M2 起）
- 目录归并：spike 用了 FRB 默认的 `flutter/rust/`（crate `rust_lib_cliphist`）；M2 需与 repo 根 `rust/evdev-helper/` 合并为 `rust/Cargo.toml` workspace（`rust-core` + `evdev-helper`），并更新 `flutter_rust_bridge.yaml` 的 `rust_root` 与 Cargokit 路径。
- 真实 `init_app_state` + tokio runtime + 4 类后台任务（poll_clipboard / window-action 发流 / helper-status / clean_expired）。
- `ammonia` 消毒落点、`get_image_data` 改 `Vec<u8>`、11 command → `#[frb]`、5 emit → StreamSink。
- Windows / macOS 端尚未在本机验证（spike 仅 Linux）。