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

## M2 完成记录（2026-08-15）

Rust 核心全量移植进 `flutter/rust/`（crate `rust_lib_cliphist`，crate 位置不变——Cargokit 在 4 个平台文件硬编码 `../../rust` + crate 名，移动高摩擦低价值，workspace 归并推到 M8）。

**门禁全绿**：`cargo test` 16 绿（clipboard_engine 4 / hotkey_parse 5 / sanitize 5 / settings 2，与旧栈同用例）；`cargo clippy` 净；`cargo fmt --check` 净；`flutter build linux --debug` 绿。spike 的 `simple.rs`/`spike.rs`/`main.dart` 保留（Dart UI 是 M4–M6）。

**结构**：
- `src/core/`：`log` `consts` `state`(OnceLock AppState + `st()`) `settings_store` `clipboard_engine`(逐字移植 clipboard.rs) `sanitize`(ammonia) `hotkey_parse`(纯字符串 validate，去 tauri 插件类型，last-key-wins 语义) `events`(5 StreamSink 静态 + emit/register) `background`(4 线程)。
- `src/api/`：`init` `history` `settings` `clipboard` `stream`。

**11 `#[frb]` + initAppState**：getHistory(sync) / copyToClipboard / moveToTop / deleteItem / clearHistory / getImageData(→`Option<Vec<u8>>`即 `Uint8List?`，去 base64) / getSettings(sync) / updateSettings(入参改 `SettingsPatch` 结构而非 `serde_json::Value`，FRB 直接反序列化) / validateHotkey(sync) / feLog / simulatePasteCmd(M7 桩，返 Err)。

**5 StreamSink**（`crate::frb_generated::StreamSink`，存 `parking_lot::Mutex<Option<StreamSink<T>>>` 静态，emit 无订阅者时 no-op，headless 测试不阻塞）：streamClipboardChanged / streamHistoryReplace / streamItemMovedToTop(usize→Dart `BigInt`) / streamHelperStatus / streamWindowAction(`enum WindowActionKind{ShowAndRaise}`)。

**4 后台线程**（`std::thread`，**未用 tokio**——旧栈即纯 std 线程+mpsc+sleep，faithful 移植照搬；计划里写的 tokio 是务实偏离）：clipboard-poll 500ms / window-action-worker(消费 mpsc 发流，舞步本身 Dart 端 M3) / helper-status-monitor 200ms(`is_helper_connected` M8 前 stub false) / clean-expired(独立线程，启动即跑+每小时，从旧 poll 内联拆出)。

**消毒落点**：ammonia 在 add 阶段消毒后存 `html_content`（空结果回落为 None，content_type 回退）。

**副作用延后**：update_settings 的 auto_start(M5 launch_at_startup)/hotkey 注册(M7 global-hotkey)/double_tap_key 监听(M7/M8) 只校验+存+打日志，不触发 OS 效果。

**FRB 新踩坑**：`StreamSink::add` 要求 `T: SseEncode`（本 crate 默认 SseCodec），新类型在 codegen 前 `cargo check` 报 4 条 "unsatisfied trait bounds" 属正常，`flutter_rust_bridge_codegen generate` 生成 SseEncode impl 后即解。

**待办（M3 起）**：M3 窗口与托盘（window-action 舞步迁 Dart 监听器、tray 4 菜单）、M4 历史 UI、M5 设置 UI+自启、M6 富文本/图片/缩放、M7 热键与双击真监听、M8 evdev helper 拆 bin+polkit+workspace 归并、M9 CI、M10 打包。runtime e2e（真机剪贴板/双击/热键）待 M3 后手测矩阵。

## 已知后续动作（M2 起）
- 目录归并：spike 用了 FRB 默认的 `flutter/rust/`（crate `rust_lib_cliphist`）；M2 需与 repo 根 `rust/evdev-helper/` 合并为 `rust/Cargo.toml` workspace（`rust-core` + `evdev-helper`），并更新 `flutter_rust_bridge.yaml` 的 `rust_root` 与 Cargokit 路径。
- 真实 `init_app_state` + tokio runtime + 4 类后台任务（poll_clipboard / window-action 发流 / helper-status / clean_expired）。
- `ammonia` 消毒落点、`get_image_data` 改 `Vec<u8>`、11 command → `#[frb]`、5 emit → StreamSink。
- Windows / macOS 端尚未在本机验证（spike 仅 Linux）。