# ClipHist

一个简洁的剪贴板历史管理器，支持 Windows、macOS 和 Linux。

## 功能

- 📋 监听剪贴板变化，自动记录历史
- 🔍 快速搜索历史记录
- ⌨️ 键盘导航（方向键选择，Enter 复制）
- 💾 本地持久化存储
- 🎨 原生界面，响应迅速
- 🔒 纯本地存储，不上传任何数据

## 安装

### Windows

从 [Releases](https://github.com/ping/cliphist/releases) 下载 `.msi` 或 `.exe` 安装包。

### macOS / Linux

从Releases下载对应平台的安装包，或自行编译。

## 编译

需要 Rust 1.70+ 和 Node.js 18+。

```bash
# 安装依赖
npm install

# 开发模式
npm run tauri dev

# 编译发布版本
npm run tauri build
```

## 技术栈

- Tauri 2（Rust 后端 + Web 前端）
- 剪贴板监控：arboard
- 前端：原生 HTML/CSS/JS

## 快捷键

| 按键 | 动作 |
|------|------|
| `↑` / `↓` | 在列表中导航 |
| `Enter` | 复制选中项 |
| `Esc` | 取消搜索 |
| 鼠标双击 | 复制该项 |
