# ClipHist: 现代化 UI 重构方案

> **背景**：此方案替代了之前的 Slint 迁移方案。核心判断是——痛点在于 UI 在 KDE 上不够原生，
> 而非框架本身。Rust 后端 1500+ 行代码稳定运行，不应为前端问题而重写整个技术栈。
> 新方案在现有 Tauri v2 基础上，只重做前端，实现零 Rust 后端改动。

## 原则

- **零改动 Rust 后端** — `src-tauri/src/` 下所有 `.rs` 文件一字不改
- **零改动 Tauri 插件** — opener, clipboard-manager, global-shortcut, autostart 全部保留
- **只改前端** — 替换 `src/` 目录下的 HTML/CSS/JS，引入现代前端框架
- **去掉 GTK 标题栏** — `decorations: false`，前端自绘 KDE Breeze 风格标题栏

## 当前状态（重构前）

```
cliphist/
├── src/                        ← 前端（待替换）
│   ├── index.html              ← 173 行，HTML 结构
│   ├── main.js                 ← 495 行，全部 JS 逻辑（IPC/渲染/键盘/设置）
│   ├── styles.css              ← 661 行，全部样式
│   └── assets/                 ← SVG 图标
├── src-tauri/                  ← 仅改 tauri.conf.json 一行
│   ├── src/                    ← 不动（11 个 .rs 文件，~1500 行）
│   ├── Cargo.toml              ← 不动
│   ├── tauri.conf.json         ← 改 decorations: true → false（见下方）
│   ├── capabilities/           ← 不动
│   └── icons/                  ← 不动
├── target/                     ← 构建产物
└── ...
```

### 前端现有功能（全部需在新前端中复现）

| 功能 | 当前实现 |
|------|---------|
| 历史列表渲染 | 文本/图片/链接/短文本/富文本，五种样式+图标 |
| 搜索过滤 + 清除按钮 | `search_history` Tauri 命令 |
| 分类标签 | 全部/图片/文本/链接/短文本/富文本，选中高亮 |
| 键盘导航 | ↑↓ 选择、Enter 复制、Esc 关闭搜索、1-9 快捷键 |
| 设置面板 | 全屏覆盖：开关类 + 缩放 + 快捷键输入 + 双击键选择 + 保留时长 |
| Toast 通知 | 顶部滑入提示动画 |
| 状态栏 | 监听状态 + 记录数 + 快捷键提示 |
| 系统托盘集成 | 通过 Tauri emit('open-settings') 通信 |
| 窗口控制 | 关闭到托盘、最小化、`decorations: false` 后自绘 |
| 缩放 | 整体 CSS zoom 缩放 |
| 主题 | CSS 变量，亮色/暗色自适应 |

### 前端调用的 Tauri IPC 接口（不变）

所有 `invoke()` 和 `listen()` 的调用签名保持不变：

```js
invoke('get_history')
invoke('search_history', { query })
invoke('copy_to_clipboard', { id })
invoke('delete_item', { id })
invoke('clear_history')
invoke('get_item_count')
invoke('get_settings')
invoke('save_settings_cmd', { settings })
invoke('update_settings', { partial })
invoke('validate_hotkey', { hotkey })
invoke('toggle_autostart', { enable })
invoke('simulate_paste_cmd')

listen('clipboard-changed', callback)
listen('open-settings', callback)
```

## 关键变更：tauri.conf.json 修改

只改一个值——删除 GTK 标题栏，交由前端完全自绘：

```diff
 {
   "app": {
     "windows": [
       {
-        "decorations": true,
+        "decorations": false,
       }
     ]
   }
 }
```

### 改前 vs 改后对比

| | 改前 `decorations: true` | 改后 `decorations: false` |
|---|---|---|
| 标题栏来源 | GTK CSD（KDE Wayland 上默认走 GTK 自绘） | **前端 CSS 自绘** |
| 窗口按钮 | GTK 风格（靠右、扁平） | KDE Breeze 风格（靠左、圆按钮） |
| 窗口拖拽 | GTK 处理 | 前端 `-webkit-app-region: drag` |
| KDE 快捷键（Alt+F3 菜单等） | 正常 | 正常（KWin 接管，与内容区无关） |
| 窗口阴影 | GTK 提供 | 前端 CSS `box-shadow` 模拟 |

### 自绘标题栏的窗口控制

`decorations: false` 后，需要前端处理以下操作，这些都有 Tauri API：

```js
import { getCurrentWindow } from '@tauri-apps/api/window';

const appWindow = getCurrentWindow();

// 最小化
document.getElementById('btn-minimize').onclick = () => appWindow.minimize();

// 关闭（根据设置决定真正关闭还是隐藏到托盘）
document.getElementById('btn-close').onclick = () => {
  if (closeToTray) {
    appWindow.hide();
  } else {
    appWindow.close();
  }
};
```

## 前端技术栈选择

| 框架 | 产物大小 | 上手速度 | 与 Tauri 集成 | 推荐度 |
|------|---------|---------|-------------|-------|
| **Svelte 5 (推荐)** | ~5KB gzip | 最快，语法极简 | 原生 web 输出，直接挂载 | ★★★★★ |
| Solid.js | ~8KB gzip | 快，JSX 无 vDOM | 同上 | ★★★★☆ |
| Vue 3 | ~15KB gzip | 快 | 同上 | ★★★★☆ |
| React | ~35KB gzip | 快 | 同上 | ★★★☆☆ |
| Vanilla | 0KB | 最快 | 同上 | ★★☆☆☆ |

**推荐 Svelte 5** 的理由：
- 编译型框架，产物直接是原生 ES 模块，无运行时开销
- runes 语法（`$state`, `$derived`, `$effect`）天然适合 Tauri 的 invoke/listen 异步模式
- 单文件组件（`.svelte`）把 HTML/JS/CSS 放在一个文件里，重构现有 3 个文件（html/js/css）的映射关系非常直观
- 极小的包体积让 WebView 加载几乎无感
- Tauri 官方示例中 Svelte 是 first-class 支持（`create-tauri-app` 可选模板）

## 重构后的文件结构

```
src/
├── app.svelte                  ← 根组件，含自绘标题栏 + 布局
├── main.ts                     ← 入口，初始化 Tauri listener + 挂载 Svelte
├── lib/
│   ├── titlebar.svelte         ← 自绘 KDE Breeze 风格标题栏
│   ├── history-list.svelte     ← 历史列表 + 分类标签 + 搜索
│   ├── history-item.svelte     ← 单个历史条目（五种类型渲染）
│   ├── settings-panel.svelte   ← 设置面板（全屏覆盖）
│   ├── toast.svelte            ← Toast 通知
│   ├── statusbar.svelte        ← 状态栏
│   └── category-tabs.svelte    ← 分类标签按钮组
├── stores/
│   └── clipboard.ts            ← 全局状态：history, selectedIndex, searchQuery 等
├── styles/
│   ├── global.css              ← 全局样式变量 + reset
│   ├── titlebar.css            ← 标题栏专属样式
│   └── app.css                 ← 主布局样式
├── types.ts                    ← TypeScript 类型定义（匹配 Rust 端数据结构）
├── index.html                  ← HTML 入口（#app 挂载点）
├── vite-env.d.ts               ← Vite 类型声明
├── package.json
├── svelte.config.js
├── vite.config.ts
└── tsconfig.json
```

> TypeScript 是可选的。如果不想引入 TS 编译步骤，所有 `.svelte` 文件仍可以使用
> `<script>`（纯 JS）代替 `<script lang="ts">`。推荐 TS 是因为 Tauri invoke 的返回值
> 类型化能避免大量调试时间。

## 设计原则 — KDE 原生感

### 标题栏（最关键的部分）

`decorations: false` 后，前端需要完整复刻 KDE Breeze 标题栏：

```
┌──────────────────────────────────────────────────┐
│ [─ □ ✕]  ClipHist - 剪贴板历史    ← app region: drag
│  ────── ← 1px 分隔线                              │
└──────────────────────────────────────────────────┘
```

**布局规范：**
- 高度 32px（KDE Breeze 标准）
- 按钮组 **靠左**（KDE 约定），顺序：关闭 → 最小化 → 最大化（这里是关闭 → 最小化，不需要最大化）
- 应用名居左，跟在按钮后面，间隔 8px
- 拖拽区域覆盖整个标题栏
- 底部 1px 分隔线，颜色 `--border`

**按钮样式（Breeze 风格圆形按钮）：**

```css
.titlebar-btn {
  width: 20px;
  height: 20px;
  border-radius: 50%;
  border: none;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  cursor: pointer;
  transition: background 0.15s;
}

/* KDE Breeze 标准的红/灰/黄配色 */
.btn-close           { background: #e53e30; }  /* 红色 */
.btn-minimize        { background: #f6da42; }  /* 黄色 */
/* hover 时加深 */
.btn-close:hover     { background: #c7362a; }
.btn-minimize:hover  { background: #dbc338; }
```

> Breeze 标题栏按钮默认不显示图标，只显示色块。用户通过颜色和位置区分功能。
> 如果要加图标，用白色半透明 SVG 覆盖在色块上。

### 字体

```
font-family: "Noto Sans SC", "Noto Sans", system-ui, -apple-system, sans-serif;
```

- 优先使用系统字体（KDE 默认 Noto Sans），不要加载任何网络字体
- 字号控制在 13-14px 基础，设置面板等次要区域 12-13px

### 配色

```css
:root {
  --bg-primary: #eff0f1;      /* KDE 标准背景 */
  --bg-secondary: #fcfcfc;    /* KDE 卡片色 */
  --bg-hover: #e4e4e4;       /* KDE 悬停高亮 */
  --text-primary: #232629;   /* KDE 正文色 */
  --text-secondary: #76787d; /* KDE 辅助色 */
  --accent: #3daee9;         /* KDE Plasma 蓝 */
  --accent-hover: #3498d6;
  --border: #bcbec0;          /* KDE 边框色 */
  --radius: 6px;              /* KDE 小圆角 */
  --radius-sm: 4px;
}
```

- 未来可以通过 `@media (prefers-color-scheme: dark)` 支持暗色

### 间距与布局

```
--space-xs: 4px
--space-sm: 8px
--space-md: 12px
--space-lg: 16px
--space-xl: 24px
```

- 使用 KDE 约定的 4px 网格系统
- 列表项间距 4px 而不是 8px，营造紧凑感
- 分类标签、按钮、输入框使用 KDE 的 22-28px 高度规范

### 交互细节

- 列表项选中使用 KDE 风格的色块高亮（浅蓝背景），而非勾选/复选
- 悬停效果使用 `background: var(--bg-hover)`，过渡时间 150ms
- 滚动条使用 thin scrollbar，与 Konsole/Dolphin 风格一致
- 搜索框获得焦点时显示边框高亮（KDE 风格蓝色外发光）

## 分步执行计划

| 步 | 内容 | 产出 | 预估时间 |
|----|------|------|---------|
| **1** | 初始化构建环境：`package.json` + `vite.config.ts` + Svelte 配置 | `npm run dev` 能启动，浏览器看到空白 Svelte 页面 | 20 min |
| **2** | 改 `tauri.conf.json` 的 `decorations` 为 `false`，验证窗口无标题栏 | 无标题栏的空白窗口 | 10 min |
| **3** | 自绘标题栏：`titlebar.svelte`，KDE Breeze 风格，包含拖拽区 + 关闭/最小化按钮（调用 Tauri window API） | 窗口可拖拽、可关闭、可最小化 | 1 h |
| **4** | 验证 Tauri IPC 通路：前端 `invoke('get_settings')` 能正常调用 | Tauri + Vite 联调通 | 20 min |
| **5** | 全局样式 + 布局框架：用 KDE 调色板变量搭建 `app.svelte` 主布局（标题栏 + 搜索区 + 列表区 + 状态栏 + 设置面板遮罩） | 完整的窗口骨架 | 1 h |
| **6** | 状态管理 + `clipboard-changed` 事件绑定：`stores/clipboard.ts` 监听后端事件，维护响应式数据 | 后端数据变化时 store 自动更新 | 30 min |
| **7** | 分类标签 + 搜索框：`category-tabs.svelte` + 搜索输入，`invoke('search_history')` 联动 | 搜索和分类切换功能可用 | 1 h |
| **8** | 历史列表渲染：`history-list.svelte` + `history-item.svelte`，五种类型样式 + 图标 + 预览截断 | 列表完整展示 | 2 h |
| **9** | 键盘导航：↑↓ 选择、Enter 复制、Esc 关闭搜索、1-9 数字键 | 全键盘操作可用 | 1 h |
| **10** | 设置面板：`settings-panel.svelte`，全部开关/输入/下拉 + invoke 保存 | 设置可读可写 | 2 h |
| **11** | Toast 动画 + 状态栏：复制成功/失败的反馈动画，快捷键提示显示 | 交互反馈完整 | 1 h |
| **12** | 窗口控制逻辑完善：关闭到托盘（调用 `appWindow.hide()`）、最小化、设置面板打开（on `open-settings` 事件） | 窗口行为完整 | 30 min |
| **13** | 缩放功能：通过 CSS zoom/scale 实现，响应 `update_settings` 的 zoom_level | 缩放可用 | 30 min |
| **14** | 暗色模式适配 + 打磨：响应 `prefers-color-scheme: dark`，微调过渡动画、聚焦态、滚动条 | 最终 polish | 1-2 h |

**预估总工时：11-14 小时**

## 风险点与缓解措施

| 风险 | 影响 | 缓解 |
|------|------|------|
| Vite dev server 与 Tauri 静态文件路径配置冲突 | 构建时才能发现集成问题 | 使用 `create-tauri-app` 推荐的 Svelte 模板确保路径一致 |
| Tauri v2 的 `withGlobalTauri: true` 在 Svelte 中不可用 | 前端无法访问 `window.__TAURI__` | 使用 `@tauri-apps/api` npm 包 |
| Svelte 5 runes 语法与旧版 Svelte 差异大 | 开发时需要查文档 | Svelte 5 稳定版已发布，文档完备 |
| 图片类型历史项的性能 | 大量图片时列表卡顿 | 保持当前 Rust 端的图片缩略图逻辑不变，前端只展示已压缩的 base64 |
| `decorations: false` 后失去原生窗口阴影 | 窗口看起来"浮"得不够 | 前端 CSS 用 `box-shadow` 模拟，或走 tauri window API 设置阴影 |
| 分类标签高亮颜色与 KDE 调色板不符 | 视觉不协调 | 用 CSS 变量统一管理 |

## 设计方案附录

### Svelte 5 状态管理模式（参考）

```ts
// stores/clipboard.ts
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { writable, derived } from 'svelte/store';

export const history = writable<ClipboardItem[]>([]);
export const selectedIndex = writable(-1);
export const searchQuery = writable('');
export const currentCategory = writable('all');

// 派生出经过搜索和分类过滤的列表
export const filteredHistory = derived(
  [history, searchQuery, currentCategory],
  ([$history, $query, $cat]) => {
    return $history.filter(item => {
      if ($cat !== 'all' && item.content_type !== $cat) return false;
      if ($query && !item.content.toLowerCase().includes($query.toLowerCase())) return false;
      return true;
    });
  }
);

// 初始化：加载历史 + 监听后端推送
export async function initClipboard() {
  const items = await invoke<ClipboardItem[]>('get_history');
  history.set(items);

  await listen<ClipboardItem[]>('clipboard-changed', (event) => {
    history.set(event.payload);
  });
}
```

### 组件结构示意

```
app.svelte
├── <Titlebar>            ← lib/titlebar.svelte（自绘标题栏，窗口控制）
├── <div class="search-container">
│   ├── <CategoryTabs>   ← lib/category-tabs.svelte
│   └── <input> 搜索框
├── <HistoryList>        ← lib/history-list.svelte
│   └── <HistoryItem>    ← lib/history-item.svelte (×N)
├── <StatusBar>          ← lib/statusbar.svelte
├── <Toast />            ← lib/toast.svelte
└── <SettingsPanel>      ← lib/settings-panel.svelte（条件渲染，覆盖层）
```

### Tauri invoke 调用封装（参考）

```ts
// lib/tauri-commands.ts
import { invoke } from '@tauri-apps/api/core';
import type { ClipboardItem, Settings } from '../types';

export async function getHistory(): Promise<ClipboardItem[]> {
  return invoke('get_history');
}

export async function searchHistory(query: string): Promise<ClipboardItem[]> {
  return invoke('search_history', { query });
}

export async function copyToClipboard(id: number): Promise<void> {
  return invoke('copy_to_clipboard', { id });
}

export async function deleteItem(id: number): Promise<void> {
  return invoke('delete_item', { id });
}

export async function clearHistory(): Promise<void> {
  return invoke('clear_history');
}

export async function getSettings(): Promise<Settings> {
  return invoke('get_settings');
}

export async function updateSettings(partial: Partial<Settings>): Promise<Settings> {
  return invoke('update_settings', { partial });
}

/* --- 窗口控制 --- */
import { getCurrentWindow } from '@tauri-apps/api/window';
const appWindow = getCurrentWindow();

export function minimizeWindow() { appWindow.minimize(); }
export function closeWindow(closeToTray: boolean) {
  if (closeToTray) { appWindow.hide(); }
  else { appWindow.close(); }
}
```

### 关键库版本参考

```json
{
  "devDependencies": {
    "@sveltejs/vite-plugin-svelte": "^5.0.0",
    "svelte": "^5.0.0",
    "svelte-check": "^4.0.0",
    "typescript": "^5.6.0",
    "vite": "^6.0.0"
  },
  "dependencies": {
    "@tauri-apps/api": "^2.0.0"
  }
}
```

### Vite 配置要点

```ts
// vite.config.ts
import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

export default defineConfig({
  plugins: [svelte()],
  build: {
    outDir: '../src-tauri/dist',
    emptyOutDir: true,
  },
  server: {
    port: 1420,
    strictPort: true,
  },
});
```

需要在 `tauri.conf.json` 中更新 `frontendDist`：
```diff
 {
   "build": {
-    "frontendDist": "../src"
+    "frontendDist": "../src-tauri/dist"
   }
 }
```

### 初始步骤（Step 1 详细）

```bash
cd cliphist

npm init -y
npm install --save-dev @sveltejs/vite-plugin-svelte svelte vite typescript
npm install @tauri-apps/api

mkdir -p src/lib src/stores src/styles

cat > src/index.html << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>ClipHist</title>
  <link rel="stylesheet" href="/src/styles/global.css" />
</head>
<body>
  <div id="app"></div>
  <script type="module" src="/src/main.ts"></script>
</body>
</html>
EOF

cat > src/main.ts << 'EOF'
import { mount } from 'svelte';
import App from './app.svelte';

const app = mount(App, { target: document.getElementById('app')! });
export default app;
EOF
```

> 实际开发时推荐把旧的 `index.html`、`main.js`、`styles.css` 备份后移出 `src/` 目录，
> 避免与新的文件冲突。可以在项目根目录建一个 `src-archive/` 暂存旧前端。

### Step 2-3 详细（标题栏自绘）

**改 tauri.conf.json：**
```diff
 {
   "app": {
     "windows": [
       {
         "title": "ClipHist",
         "width": 400,
         "height": 500,
+        "decorations": false,
-        "decorations": true,
       }
     ]
   }
 }
```

**titlebar.svelte 骨架：**
```svelte
<script lang="ts">
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import { closeToTray } from '../stores/clipboard';

  const appWindow = getCurrentWindow();

  function handleClose() {
    if ($closeToTray) {
      appWindow.hide();
    } else {
      appWindow.close();
    }
  }

  function handleMinimize() {
    appWindow.minimize();
  }
</script>

<header class="titlebar" data-tauri-drag-region>
  <div class="titlebar-buttons">
    <button class="titlebar-btn btn-close" onclick={handleClose} aria-label="关闭" />
    <button class="titlebar-btn btn-minimize" onclick={handleMinimize} aria-label="最小化" />
  </div>
  <span class="titlebar-title">ClipHist</span>
</header>

<style>
  .titlebar {
    display: flex;
    align-items: center;
    height: 32px;
    padding: 0 8px;
    background: var(--titlebar-bg, #ecedee);
    border-bottom: 1px solid var(--border);
    user-select: none;
  }
  .titlebar-buttons {
    display: flex;
    gap: 6px;
    margin-right: 8px;
  }
  .titlebar-btn {
    width: 20px; height: 20px;
    border-radius: 50%;
    border: none;
    padding: 0;
    cursor: pointer;
  }
  .btn-close { background: #e53e30; }
  .btn-close:hover { background: #c7362a; }
  .btn-minimize { background: #f6da42; }
  .btn-minimize:hover { background: #dbc338; }
  .titlebar-title {
    font-size: 13px;
    color: var(--text-primary);
  }
</style>
```

注意：`data-tauri-drag-region` 属性替换了旧版 Tauri 的 `-webkit-app-region: drag` CSS 属性，
是 Tauri v2 推荐的拖拽区域声明方式。整个标题栏的容器上加上这个属性即可。

---

> 此文档完成后，后续开发可参照此计划逐步实现前端重构。
> 关键决策：`decorations: false` + 前端自绘标题栏，消除 GTK CSD 对窗口外观的影响。
> Rust 后端 0 改动，Tauri 配置只改 1 个值。
