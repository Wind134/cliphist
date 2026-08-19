# ClipHist

轻量、快速的跨平台剪贴板历史管理器。桌面端已迁移到 Flutter + Rust，支持 Windows、macOS 和 Linux。

## 功能

- 📋 实时监听剪贴板变化，自动记录文本、富文本与图片
- 🔍 即时搜索与分类筛选，支持 1–9 快捷粘贴
- ⌨️ 全局快捷键呼出/隐藏窗口，支持键盘导航
- 💾 本地 JSON 持久化，图片外置存储、原子写入、按需加载
- 🖥️ 现代化 Flutter 界面与系统原生窗口/托盘集成
- 🔒 剪贴板数据完全保留在本地；检查更新时仅访问 GitHub Releases
- ⬆️ 启动后静默检查新版本，也可在设置/托盘中手动检查

## 安装

从 [Releases](https://github.com/Wind134/cliphist/releases) 下载对应平台的安装包。

| 平台 | 格式 |
|------|------|
| Windows | `.exe` / `.msix` |
| macOS (Apple Silicon) | `.dmg` |
| Linux | `.deb` / `.AppImage` |

## 开发编译

需要 Flutter 3.44.9（Dart 3.12）与稳定版 Rust。Linux 还需要 GTK3、AppIndicator、Keybinder、libevdev 与 udev 开发包。

```bash
cd flutter
flutter pub get
flutter run -d linux       # 或 windows / macos

# 质量门禁
flutter analyze
flutter test
cd rust
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test
```

## 技术架构

- 界面与桌面集成：Flutter（Riverpod、window_manager、tray_manager）
- 核心：Rust（剪贴板监控、历史持久化、双击监听与粘贴注入）
- 跨语言桥接：flutter_rust_bridge 2.12
- 存储：JSON 文件（图片为 `images/<id>.png`）
- 剪贴板：arboard

应用源码与桌面发布产物均由 `flutter/` 构建；Linux 的特权键盘辅助进程位于 `rust/evdev-helper/`。

## 快捷键

| 快捷键 | 动作 |
|--------|------|
| `Ctrl+Shift+V` | 呼出窗口（可在设置中修改） |
| `↑` / `↓` | 列表导航 |
| `Enter` | 复制选中项 |
| `1`–`9` | 快捷粘贴对应记录 |
| `Esc` | 取消搜索 / 关闭窗口 |
| 鼠标双击 | 复制该项 |

## 平台说明

- Linux X11 直接支持全局快捷键；Wayland 请在桌面环境中将系统快捷键绑定到 `cliphist --toggle-window`。
- Linux 的双击修饰键和自动粘贴依赖 evdev helper，安装 `.deb` 或 AUR 包后首次使用会弹出授权提示；AppImage 不包含该权限组件。
- macOS 上双击键监听和自动粘贴需要在“系统设置 → 隐私与安全性 → 辅助功能”中授权。
