<footer class="statusbar">
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
