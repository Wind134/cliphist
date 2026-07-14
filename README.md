# ClipHist

轻量、快速的跨平台剪贴板历史管理器，支持 Windows、macOS 和 Linux。系统启动即常驻后台，随时呼出随时粘贴。

## 功能

- 📋 实时监听剪贴板变化，自动记录文本与图片历史
- 🔍 模糊搜索，快速定位历史记录
- ⌨️ 全局快捷键呼出/隐藏窗口，键盘导航选择
- 💾 本地 JSON 持久化存储（图片外置为独立文件，原子写、按需加载），重启数据不丢失
- 🪟 系统原生窗口装饰（标题栏/最小化/关闭/缩放由 OS 接管）
- 🔒 完全本地运行，不联网不上传
- 🖥️ 系统托盘常驻，开机自启（可选静默启动）

## 安装

从 [Releases](https://github.com/Wind134/cliphist/releases) 下载对应平台的安装包即可。

| 平台 | 格式 |
|------|------|
| Windows | `.msi` / `.exe` |
| macOS (Intel) | `.dmg` |
| macOS (Apple Silicon) | `.dmg` |
| Linux | `.deb` / `.AppImage` |

## 开发编译

需要 Rust 1.70+ 和 Node.js 22+。

```bash
# 安装依赖
npm install

# 开发模式
npm run tauri dev

# 编译发布版本
npm run tauri build
```

## 技术架构

- 框架：Tauri 2
- 后端：Rust（剪贴板监控、快捷键、系统托盘、窗口管理）
- 前端：Svelte 5（Tauri 集成 UI，窗口装饰由 OS 接管）
- 存储：JSON 文件（图片外置为 `images/<id>.png`，原子写、按需加载）
- 剪贴板：arboard
- 对话框：@tauri-apps/plugin-dialog（系统原生确认框）

## 快捷键

| 快捷键 | 动作 |
|--------|------|
| `Ctrl+Shift+V` | 呼出 / 隐藏窗口（可在设置中修改） |
| `↑` / `↓` | 列表导航 |
| `Enter` | 复制选中项到剪贴板 |
| `Esc` | 取消搜索 / 关闭窗口 |
| 鼠标双击 | 复制该项 |
