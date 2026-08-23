# ClipHist 架构说明

## 概览

ClipHist 是一个 Flutter + Rust 桌面剪贴板历史工具。Flutter 负责界面、窗口、托盘和系统快捷键；Rust 负责剪贴板监控、历史持久化、双击修饰键监听和粘贴注入。两端通过 `flutter_rust_bridge` 调用和事件流协作。

## 目录结构

```text
cliphist/
├── flutter/                     # 桌面应用与主 Rust 核心
│   ├── lib/
│   │   ├── main.dart              # 启动、单例检查、FRB 初始化
│   │   ├── app_controller.dart    # 窗口、托盘、快捷键和退出生命周期
│   │   ├── state/                 # Riverpod 状态
│   │   ├── ui/                    # 历史、类别、设置、状态栏和主题
│   │   ├── update/                # GitHub Releases 更新检查
│   │   └── src/rust/              # FRB 生成的 Dart 绑定
│   ├── rust/
│   │   ├── src/api/               # 对 Dart 暴露的命令和事件流
│   │   └── src/core/              # 剪贴板、存储、设置、双击与单例
│   ├── rust_builder/              # Cargokit/Flutter Rust 构建集成
│   ├── assets/icon/              # 应用与托盘图标源文件
│   └── linux|macos|windows/       # 平台工程
├── rust/evdev-helper/           # Linux 特权键盘监听/粘贴辅助进程
├── packaging/linux/             # Linux policy 和安装脚本
├── PKGBUILD*                    # Arch Linux 打包
└── .github/workflows/           # 检查、测试和多平台发布
```

## 运行时分层

```text
用户交互
   │
   ▼
Flutter UI ── Riverpod 状态
   │              ▲
   │ FRB 调用     │ FRB StreamSink
   ▼              │
Rust API ── Rust Core ── history.json / images / settings.json
                    │
                    └── 剪贴板、键盘监听、粘贴注入
```

### Flutter 层

- `main.dart` 初始化桌面窗口和 Rust 动态库，执行单例检查，然后启动 UI 和应用控制器。
- `ClipHistController` 是原生桌面生命周期的唯一协调者，处理托盘菜单、全局快捷键、窗口唤醒、快捷粘贴和立即退出。
- Riverpod 保存历史列表、过滤条件、设置、连接状态和更新检查结果。
- `ui/` 仅消费状态并触发控制器/API，不直接读写持久化文件。

### Rust 层

- `api/` 定义 FRB 公开边界：初始化、历史读写、剪贴板操作、设置更新和事件流。
- `core/state.rs` 持有进程内唯一状态；历史、设置和窗口唤醒请求都通过该状态协调。
- 三个常驻任务负责剪贴板监听、Linux helper 状态监控和过期历史清理；Linux 使用 Wayland data-control selection 事件，Windows/macOS 保留 arboard 轮询。窗口唤醒通过原子合并标记交给 Flutter UI isolate。
- 文本、HTML、图片和文件列表按完整 MIME 组合去重；图片保存为独立 PNG，UI 仅在需要显示时读取字节。

## 关键流程

### 记录剪贴板

1. Rust 后台任务监听系统剪贴板；Linux 从同一个 Wayland selection 读取全部可用 MIME。
2. 新内容经去重、富文本清理、文件 URI 解析和图片外置后原子写入历史文件。
3. Rust 通过 FRB 事件流发送最新快照。
4. Flutter 合并 Riverpod 状态并刷新列表。

### 唤醒与快捷粘贴

1. 托盘、全局快捷键或双击修饰键产生窗口动作请求。
2. Flutter UI isolate 消费合并后的请求，执行显示、聚焦和置顶切换。
3. 数字键 `1`–`9` 选中条目后，Rust 将内容写回剪贴板；Linux 会同时恢复文本、HTML、PNG 和文件 URI 等表示。Flutter 隐藏窗口，再由平台实现注入 `Ctrl+V`/`Cmd+V`。
4. Linux 通过 `cliphist-evdev-helper` 完成全局修饰键监听和 uinput 粘贴；Windows/macOS 使用 `rdev`。

### 退出

托盘“退出”和不启用“关闭到托盘”时的窗口关闭都进入 `ClipHistController.quit()`。永久 FRB 事件流以进程生命周期为边界，退出路径直接结束进程，避免等待不会自行关闭的常驻流。

## 数据与安全

- 历史：`history.json`（保留上一版 `.bak`，损坏时隔离并恢复）
- 图片：`images/<id>.png`
- 设置：`settings.json`（支持缺字段迁移、集中校验和备份恢复）
- 日志：`cliphist.log`（5 MiB 轮转）
- 数据目录与文件在 Unix 上分别固定为 `0700` / `0600`；JSON 和图片均使用同步临时文件后原子替换。
- 富文本在持久化前使用 `ammonia` 清理。
- 更新检查只请求 GitHub Releases API，不上传剪贴板数据。

## 构建与验证

```bash
cd flutter
flutter pub get
flutter analyze
flutter test

cd rust
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test

cd ../../rust/evdev-helper
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test
```

CI 会重新生成 FRB 绑定并检查工作树无差异，执行严格 Flutter 分析、Rust Clippy、测试和 RustSec 审计；发布标签必须通过同一套三平台门禁后才会构建产物。
