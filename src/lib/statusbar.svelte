<script lang="ts">
  import { getCurrentWindow } from '@tauri-apps/api/window';

  const appWindow = getCurrentWindow();

  type ResizeDir = 'South' | 'SouthWest' | 'SouthEast';

  function bottomEdgeHit(el: HTMLElement, e: MouseEvent): ResizeDir | null {
    const rect = el.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    const w = rect.width;
    const h = rect.height;
    const edge = 6;
    if (y > h - edge && x < 16) return 'SouthWest';
    if (y > h - edge && x > w - 16) return 'SouthEast';
    if (y > h - edge) return 'South';
    return null;
  }

  function handleMousedown(e: MouseEvent) {
    if (e.button !== 0) return;
    const dir = bottomEdgeHit(e.currentTarget as HTMLElement, e);
    if (dir) {
      e.preventDefault();
      appWindow.startResizeDragging(dir);
    }
  }

  function handleMousemove(e: MouseEvent) {
    const dir = bottomEdgeHit(e.currentTarget as HTMLElement, e);
    (e.currentTarget as HTMLElement).style.cursor = dir || '';
  }
</script>

<footer class="statusbar" onmousedown={handleMousedown} onmousemove={handleMousemove}>
  <span class="status-indicator">监听中</span>
  <span class="shortcut-hint">双击或 Enter 复制 &middot; 1-9 快捷输入</span>
</footer>

<style>
  .statusbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    height: 24px;
    padding: 0 12px;
    background: var(--bg-secondary);
    font-size: 11px;
    color: var(--text-tertiary);
    flex-shrink: 0;
  }
  .status-indicator {
    display: flex;
    align-items: center;
    gap: 5px;
  }
  .status-indicator::before {
    content: '';
    display: inline-block;
    width: 6px;
    height: 6px;
    background: #6d6d6d;
    border-radius: 50%;
  }
  .shortcut-hint {
    opacity: 0.7;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
  }
</style>
