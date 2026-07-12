# ClipHist

轻量、快速的跨平台剪贴板历史管理器，支持 Windows、macOS 和 Linux。系统启动即常驻后台，随时呼出随时粘贴。

## 功能

- 📋 实时监听剪贴板变化，自动记录文本历史
- 🔍 模糊搜索，快速定位历史记录
- ⌨️ 全局快捷键呼出/隐藏窗口，键盘导航选择
- 💾 本地 SQLite 持久化存储，重启数据不丢失
- 🎨 无边框原生风格窗口，支持拖拽和边缘调整大小
- 🔒 完全本地运行，不联网不上传
- 🖥️ 系统托盘常驻，开机自启（可选静默启动）

## 安装

从 [Releases](https://github.com/Wind134/cliphist/releases) 下载对应平台的安装包即可。

### 各平台包格式

| 平台 | 格式 |
|------|------|
| Windows | .msi / .exe |
| macOS (Intel) | .dmg |
| macOS (Apple Silicon) | .dmg |
| Linux | .deb / .AppImage |

## 开发编译

需要 Rust 1.70+ 和 Node.js 22+。

\\ash
# 安装依赖
npm install

# 开发模式
npm run tauri dev

# 编译发布版本
npm run tauri build
\
## 技术架构

- 框架：Tauri 2
- 后端：Rust（剪贴板监控、快捷键、系统托盘、窗口管理）
- 前端：原生 HTML/CSS/JS（无框架依赖）
- 存储：SQLite（通过 rusqlite）
- 剪贴板：arboard

## 快捷键

| 快捷键 | 动作 |
|--------|------|
| \Alt + V\ | 呼出 / 隐藏窗口 |
| \↑\ / \↓\ | 列表导航 |
| \Enter\ | 复制选中项到剪贴板 |
| \Esc\ | 取消搜索 / 关闭窗口 |
| 鼠标双击 | 复制该项 |
