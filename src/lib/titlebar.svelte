<script lang="ts">
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import { settingsData, settingsOpen } from '../stores/clipboard';

  const appWindow = getCurrentWindow();

  function readCloseToTray() {
    let closeToTray = true;
    settingsData.subscribe(s => closeToTray = s.close_to_tray)();
    return closeToTray;
  }

  function handleClose(e: PointerEvent) {
    e.stopPropagation();
    if (readCloseToTray()) {
      appWindow.hide();
    } else {
      appWindow.close();
    }
  }

  function handleMinimize(e: PointerEvent) {
    e.stopPropagation();
    appWindow.minimize();
  }

  type ResizeDir = 'NorthWest' | 'NorthEast' | 'West' | 'East' | 'North';

  function edgeHitTest(el: HTMLElement, e: MouseEvent): ResizeDir | null {
    const rect = el.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    const w = rect.width;
    const edge = 8;

    if (y < edge && x < 16) return 'NorthWest';
    if (y < edge && x > w - 16) return 'NorthEast';
    if (x < 4) return 'West';
    if (x > w - 4) return 'East';
    if (y < edge) return 'North';
    return null;
  }

  const cursorMap: Record<ResizeDir, string> = {
    NorthWest: 'nw-resize',
    NorthEast: 'ne-resize',
    West: 'w-resize',
    East: 'e-resize',
    North: 'n-resize',
  };

  function handleMousedown(e: MouseEvent) {
    if (e.button !== 0) return;
    const target = e.target as HTMLElement;
    if (target.closest('.titlebar-actions')) return;
    e.preventDefault();

    const dir = edgeHitTest(e.currentTarget as HTMLElement, e);
    if (dir) {
      appWindow.startResizeDragging(dir);
    } else {
      appWindow.startDragging();
    }
  }

  function handleMousemove(e: MouseEvent) {
    const dir = edgeHitTest(e.currentTarget as HTMLElement, e);
    (e.currentTarget as HTMLElement).style.cursor = dir ? cursorMap[dir] : '';
  }
</script>

<div class="titlebar" onmousedown={handleMousedown} onmousemove={handleMousemove}>
  <div class="titlebar-left">
    <span class="titlebar-title">ClipHist</span>
  </div>
  <div class="titlebar-actions">
    <button
      class="titlebar-btn"
      class:active={$settingsOpen}
      onclick={() => settingsOpen.update(v => !v)}
      aria-label="设置"
    >
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <circle cx="12" cy="12" r="3"></circle>
        <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"></path>
      </svg>
    </button>
    <button class="titlebar-btn" onpointerdown={handleMinimize} aria-label="最小化">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
        <line x1="5" y1="12" x2="19" y2="12"></line>
      </svg>
    </button>
    <button class="titlebar-btn" onpointerdown={handleClose} aria-label="关闭">&times;</button>
  </div>
</div>

<style>
  .titlebar {
    display: flex;
    align-items: center;
    height: 32px;
    background: var(--titlebar-bg, #ecedee);
    /*removed border-bottom*/
    user-select: none;
    flex-shrink: 0;
  }
  .titlebar-left {
    display: flex;
    align-items: baseline;
    gap: 6px;
    flex: 1;
    padding-left: 12px;
  }
  .titlebar-title {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
  }
  .titlebar-actions {
    display: flex;
    gap: 2px;
    padding-right: 4px;
  }
  .titlebar-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 30px;
    height: 28px;
    border: none;
    border-radius: 4px;
    background: transparent;
    color: var(--text-secondary);
    padding: 0;
    font-size: 16px;
    cursor: pointer;
  }
  .titlebar-btn:hover {
    background: var(--bg-hover);
  }
  .titlebar-btn.active {
    background: var(--bg-active);
    color: var(--accent);
  }
</style>
