<script lang="ts">
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import { settingsData, settingsOpen } from '../stores/clipboard';

  const appWindow = getCurrentWindow();

  function handleClose(e: PointerEvent) {
    e.stopPropagation();
    let closeToTray = true;
    settingsData.subscribe(s => closeToTray = s.close_to_tray)();
    if (closeToTray) {
      appWindow.hide();
    } else {
      appWindow.close();
    }
  }

  function handleMousedown(e: MouseEvent) {
    if (e.button !== 0) return;
    const target = e.target as HTMLElement;
    if (target.closest('.titlebar-actions')) return;
    e.preventDefault();

    // Check if mouse is near the titlebar edges for resize
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    const w = rect.width;
    const h = rect.height;
    const edge = 8;

    if (y < edge && x < 16) {
      appWindow.startResizeDragging('NorthWest');
    } else if (y < edge && x > w - 16) {
      appWindow.startResizeDragging('NorthEast');
    } else if (x < 4) {
      appWindow.startResizeDragging('West');
    } else if (x > w - 4) {
      appWindow.startResizeDragging('East');
    } else if (y < edge) {
      appWindow.startResizeDragging('North');
    } else {
      appWindow.startDragging();
    }
  }

  function handleMousemove(e: MouseEvent) {
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    const w = rect.width;
    const h = rect.height;
    const edge = 8;

    if (y < edge && x < 16) {
      titlebar.style.cursor = 'nw-resize';
    } else if (y < edge && x > w - 16) {
      titlebar.style.cursor = 'ne-resize';
    } else if (x < 4) {
      titlebar.style.cursor = 'w-resize';
    } else if (x > w - 4) {
      titlebar.style.cursor = 'e-resize';
    } else if (y < edge) {
      titlebar.style.cursor = 'n-resize';
    } else {
      titlebar.style.cursor = '';
    }
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
    <button
    <button class="titlebar-btn" onpointerdown={handleClose} aria-label="关闭">&times;</button>
  </div>

</div>

<style>
  .titlebar {
    display: flex;
    align-items: center;
    height: 32px;
    background: var(--titlebar-bg, #ecedee);
    border-bottom: 1px solid var(--border);
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
