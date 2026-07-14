# ClipHist 优化清单

> 整理自 2026-07-13 对 `dev` 分支的代码走查。按影响程度分级，便于排期。
> 当前分支状态：`a06c8c7 docs: fix README formatting`（main 干净）。
>
> **本次 release（分支 `release/202607`）新增两项贯穿性目标**（用户 2026-07-13 补充）：
> - **A. 不再自绘窗口 UI，改用系统集成的 UI** —— 让 OS 接管标题栏、最小化/关闭、窗口缩放；弹窗/确认用系统原生对话框。见新增 #14 / #15。
> - **B. 轻量、节省资源** —— 贯穿所有改动的主线：砍掉死重（插件/依赖/命令）、解决存储 I/O 与内存瓶颈（#3/#4/#5）、收敛运行期线程与重复逻辑（#10/#13）。

---

## 🔴 一、功能 / 正确性（影响实际体验，建议优先）

### 1. 窗口缩放（zoom）在 Linux / macOS 上完全失效
- **位置**：`src/stores/clipboard.ts:141-143`（`applyZoom`）
- **问题**：使用 `document.documentElement.style.zoom = ...`。`zoom` 是 Chromium 私有 CSS 属性，而 Tauri 在 **Linux 用 WebKitGTK、macOS 用 WKWebView，均不支持 `zoom`**。因此该设置在 Windows 生效，在 Linux/macOS 静默无效。
- **建议**：改用 `transform: scale()` 或根字体大小缩放，并对布局做相应适配（scale 会撑大容器，需配合 `transform-origin` 与外层尺寸调整）。
- **涉及**：`zoomDown` / `zoomUp`（`src/lib/settings-panel.svelte`）、`zoom_level` 持久化字段。

### 2. 文档与代码严重脱节
- **README.md**：声称「前端：原生 HTML/CSS/JS（无框架依赖）」「存储：SQLite（通过 rusqlite）」。实际前端是 **Svelte 5**，存储是 **JSON 文件**（`history.json` / `settings.json`）。
- **ARCHITECTURE.md**：同样声称「无框架」「SQLite」，且目录结构描述的是已不存在的文件（`main.js`、`icon_gen.rs`、旧的窗口配置 `decorations: true` 等）。
- **建议**：更新两份文档，使其与现状一致（Svelte 5 + arboard + JSON 存储 + 各 Tauri 插件清单）。可作为后续优化的配套改动。

---

## 🟠 二、性能（最值得投入，核心瓶颈）

### 3. 每次复制都全量重写整个 `history.json` ⭐ 最大瓶颈
- **位置**：`src-tauri/src/clipboard.rs:31`（`save_history`）被 `lib.rs:479` / `lib.rs:558` 每次新条目调用。
- **问题**：`save_history` 把整个 `Vec<ClipboardItem>` 序列化为 pretty JSON 后整文件写入。`MAX_HISTORY = 500`，若含图片（见 #4），每次剪贴板变化都可能重写几十 MB 文件。
- **建议**：改为「增量追加 / 预写 + 原子替换」，或低频批量落盘（如合并 N 次变更后写一次，或 debounce）。结合 #4 可大幅降低写入量。

### 4. 图片以 base64 内联进 JSON，文件无限膨胀
- **位置**：`src-tauri/src/lib.rs:503-547`（`poll_clipboard` 图片分支）。
- **问题**：每张剪贴板图片 re-encode 为 PNG → base64 → 存入 `image_data` 字段，导致历史 JSON 同时承载元数据与原始图数据，磁盘 + 内存双压力。
- **建议**：图片按 id 单独存文件（如 `ClipHist/images/<id>.png`），JSON 只存路径/尺寸；读取时按需加载。可同时缓解 #3 的写入放大。

### 5. 日志每次写盘都 open → write → flush → close
- **位置**：`src-tauri/src/log.rs:11`（`write_log`）。
- **问题**：每条日志重新打开文件并 flush，频繁事件下 syscall 偏多。
- **建议**：持有复用的 append handle，或后台写线程 + 队列（注意进程退出时 flush）。保留现有 `panic::set_hook` 调用点。

---

## 🟡 三、死代码 / 未使用依赖（精简体积与编译时间）

### 6. `tauri-plugin-clipboard-manager` 注册却从未使用
- **位置**：`src-tauri/src/lib.rs:233`（init），`src-tauri/capabilities/default.json:9-10`（授权）。
- **问题**：代码全程用 `arboard` 直接读写剪贴板，前端也未引该插件。插件与权限均为死重。
- **建议**：移除 init、依赖与 capability 授权（若确认无其它用途）。

### 7. 四个未使用的 Rust 依赖
- **位置**：`src-tauri/Cargo.toml:34-40`
- **问题**：`env_logger`（`log` crate 的 init 从未调用）、`log`（自定义模块 `log.rs` 名遮蔽了 crate）、`png`（实际用的是 `image::codecs::png`）、`byteorder` 均无实际引用。
- **建议**：从 `Cargo.toml` 移除，减少编译时间与二进制体积。

### 8. 两个 Tauri 命令 + 前端函数从不被调用
- **位置**：`search_history`（`lib.rs:24`）、`get_item_count`（`lib.rs:55`）及前端 `searchHistory`（`src/stores/clipboard.ts:116`）。
- **问题**：前端用 JS 派生 store 过滤（`filteredHistory`，`clipboard.ts:29`），用 `$history.length` 计数，后端两个命令与前端封装函数均为死代码。
- **建议**：若近期无服务端搜索计划，移除命令、生成器注册与前端封装。

### 9. `ZOOM_STEP` 标了 `#[allow(dead_code)]`
- **位置**：`src-tauri/src/consts.rs:6`
- **问题**：设计残留，未被使用（UI 用 10% 步进硬编码）。
- **建议**：接上或删除。

---

## 🟢 四、代码结构 / 可维护性

### 10. 「隐藏 → 显示 → 聚焦 → 置顶」窗口逻辑复制 3 处
- **位置**：`lib.rs` setup 双击回调（`lib.rs:372-386`）、`update_settings` 双击重启（`lib.rs:110-124`）、`shortcut.rs` 全局快捷键触发（`shortcut.rs:108-114`）。
- **问题**：逻辑几乎一字不差地重复。
- **建议**：抽一个 `fn focus_main_window(app: &AppHandle)`，三处统一调用。

### 11. `DoubleTapState` 定义了两次
- **位置**：`src-tauri/src/shortcut.rs:129` 与 `src-tauri/src/evdev_helper.rs:46`。
- **问题**：主进程与 Linux helper 各自一份相同结构。
- **建议**：若结构确实一致，提取到共享模块；若语义不同，改不同名避免混淆。

### 12. `update_settings` 一长串手动 `partial.get(...)` 匹配
- **位置**：`src-tauri/src/lib.rs:72-169`
- **问题**：字段校验与赋值散落在 if 链中，新增字段易漏。
- **建议**：改为结构化校验 + 部分合并（serde `apply` / 字段级 validate 函数），更易扩展。

### 13. 双击触发每次都 `std::thread::spawn` 新 OS 线程
- **位置**：`lib.rs:372`（双重嵌套 spawn）、`update_settings` 内重启路径。
- **问题**：高频按键下线程创建开销大。
- **建议**：用 channel + 常驻工作线程处理窗口操作，hook 回调只发消息。

---

## ⚪ 五、小问题

- `clean_expired_history` 每小时重新读 `settings.json`（`lib.rs:434`）取 retention，可缓存。
- 全局键盘事件有两处监听：`app.svelte`（`svelte:window onkeydown`，处理 Esc）与 `history-list.svelte`（`onGlobalKeydown`，处理数字快贴），分散且存在潜在冲突。
- `handleClear` 使用阻塞式 `confirm()`（`history-list.svelte:131`），webview 内体验不如自定义模态。
- `get_content_type` 的 50 / 100 字符阈值较随意（`clipboard.rs:60`）。
- 生成产物 `src-tauri/dist/index.html` 被提交进 git（根 `.gitignore` 只忽略 `dist/`，未忽略 `src-tauri/dist/`），可补忽略规则。

---

## 🔵 六、本次 release 新增目标（用户 2026-07-13 补充）

### 14. 窗口改用系统原生装饰，移除自绘 UI（目标 A）
- **位置 / 涉及**：
  - `src-tauri/tauri.conf.json`：`windows[0].decorations: false` → `true`，由 OS 接管标题栏、最小化/关闭/缩放。
  - `src/lib/titlebar.svelte`：整个组件删除（自绘标题文字、`最小化/关闭/设置` 按钮、`edgeHitTest` 缩放命中测试、`startDragging`/`startResizeDragging`）。
  - `src/app.svelte`：去掉 `.window` 伪窗口外壳与 `box-shadow`、整页 `height:100vh` 布局约束，改为贴合原生窗口的内容布局。
  - `src/lib/settings-panel.svelte`：删 `handleHeaderMousedown`（`startDragging`），header 不再承担拖拽。
- **缩放（保留并现代化，用户 2026-07-13 确认）**：「窗口缩放」设置项**保留**（功能不砍）。原 `document.documentElement.style.zoom` 在 Linux/macOS 失效，改为对根内容容器用 `transform: scale()` + `transform-origin: top left`，并让外层窗口/容器尺寸做相应补偿，做到跨平台一致、观感现代的缩放。详见 #1。
- **行为调整**：「关闭时最小化到托盘」需改为监听窗口 `close-requested` 事件（`prevent` + `hide`），否则原生关闭按钮会直接退出/无法走托盘逻辑。
- **收益**：减少约 ~150 行自定义 JS 与命中测试；跨平台外观一致；修掉 #1。

### 15. 清空确认改用系统原生对话框（目标 A）
- **位置**：`src/lib/history-list.svelte:131` 的 `confirm('确定要清空…')`。
- **问题**：webview 内 `confirm()` 是浏览器样式、阻塞、与系统风格割裂。
- **建议**：引入 `@tauri-apps/plugin-dialog`，用原生 `confirm()`/`ask()` 弹系统对话框（更贴合「系统集成 UI」目标，体验一致、不阻塞渲染线程观感）。
- **代价**：需新增 `tauri-plugin-dialog` 依赖 + `capabilities` 授权（用户 2026-07-13 接受此 trade-off：当前自绘 `confirm()` 不好用）。

### 16. 设置新增「关于」展示正确版本号（目标 A 配套）
- **位置**：`src/lib/settings-panel.svelte`（新增「关于」区块）。
- **要求**：在设置里展示软件版本，且版本号**正确**（与 `tauri.conf.json` 的 `version` 一致，而非手写硬编码）。
- **实现**：前端通过 Tauri `getVersion()`（`@tauri-apps/api/app`）读取打包版本；构建/打包时由 `tauri.conf.json` 的 `version` 统一来源，避免「显示 1.0.0 但实际是别的版本」的错位。
- **收益**：用户可在设置内确认识别当前版本，便于反馈/排错；也是系统集成的标准做法。

---

## 建议优先级 / 分阶段实施计划（release/202607）

> 主线：**A. 系统集成 UI**（#14/#15 + 连带 #1）、**B. 轻量节省资源**（#3/#4/#5/#6/#7/#8/#10/#13）。
> 原则：低风险瘦身先行 → 再啃存储瓶颈 → 再做 UI 重构 → 最后收尾结构与文档。

### 阶段 0 — 瘦身 / 轻量（低风险，立刻做）
1. **#8** 移除未调用命令 `search_history` / `get_item_count` 及前端 `searchHistory` 封装。
2. **#6** 移除 `tauri-plugin-clipboard-manager`（init + `capabilities/default.json` 授权 + `Cargo.toml`）。
3. **#7** 移除未用 Rust 依赖：`env_logger` / `log` / `png` / `byteorder`。
4. **#9** 处理 `ZOOM_STEP` 的 `#[allow(dead_code)]`：随 #14 决定——若交给 OS 原生缩放则删除；若保留应用内缩放则接上该常量。
> 阶段 0 纯删减，缩二进制与启动开销，零行为变化，可单独提交。

### 阶段 1 — 核心瓶颈（资源大头，目标 B）
5. **#4** 图片外置：`images/<id>.png` 单文件存储，JSON 仅存路径/尺寸，按需加载。
6. **#3** 存储改为增量/批量落盘：debounce 合并多次变更 + 原子替换（预写临时文件再 rename），结合 #4 大幅降写入放大。
7. **#5** 日志改为复用 append handle 或后台写线程 + 队列（保留 `panic::set_hook` 调用点，退出时 flush）。
> 阶段 1 需先定存储方案（图片目录结构、增量策略）再动手；#4 是 #3 的前提。

### 阶段 2 — 系统集成 UI（目标 A，含 #1 修复与版本展示）
8. **#14** `decorations: true`，删除 `titlebar.svelte`、伪窗口外壳、`startDragging`；接 `close-requested` 走托盘逻辑。
9. **#1 + 缩放现代化** 去掉私有 `zoom`，「窗口缩放」设置**保留**，改用 `transform: scale()` + 容器尺寸补偿，跨平台一致。
10. **#15** 引入 `tauri-plugin-dialog`，`confirm()` → 原生对话框（已确认接受依赖代价）。
11. **#16** 设置新增「关于」区块，用 `getVersion()` 展示正确版本号。
> 阶段 2 改变窗口观感，全部合入 `release/202607`（用户确认不拆 PR）。

### 阶段 3 — 结构收敛 / 收尾（目标 B 延续）
11. **#10** 抽 `fn focus_main_window(app)` 统一三处「显示→聚焦→置顶」。
12. **#13** 双击/窗口操作改 channel + 常驻工作线程，取代每次 `thread::spawn`。
13. **#11** `DoubleTapState` 去重（共享模块或改名）。
14. **#12** `update_settings` 改为结构化部分合并（serde `apply` / 字段级校验）。
15. **小问题**：`clean_expired_history` 缓存 retention；键盘事件收敛到单点；补 `src-tauri/dist/` 到 `.gitignore`。
16. **#2** 对齐 `README.md` / `ARCHITECTURE.md` 与现状（Svelte 5 + arboard + JSON 存储 + 插件清单）。

---

### 若只挑最高价值的 3 个改动
1. **#3 + #4**：图片外置 + 增量存储 —— 直接解决磁盘/内存瓶颈（目标 B 核心）。
2. **#14**：系统原生窗口 UI —— 删自绘、跨平台一致、修 #1（目标 A 核心）。
3. **#6 + #7 + #8**：清理未用插件与依赖 —— 低风险瘦身、降编译与二进制体积。

> 阶段 1（#3/#4）需先设计存储方案再动手；阶段 0 与 #14 可低风险先行。
