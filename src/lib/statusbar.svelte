<script lang="ts">
  import { helperConnected } from '../stores/clipboard';
</script>

<footer class="statusbar">
  <div class="status-indicator">
    <span class="status-dot" class:connected={$helperConnected}></span>
    <span>{$helperConnected ? '快捷键就绪' : '监听中'}</span>
  </div>
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
    border-top: 1px solid var(--border);
    font-size: 11px;
    color: var(--text-tertiary);
    flex-shrink: 0;
  }
  .status-indicator {
    display: flex;
    align-items: center;
    gap: 5px;
  }
  .status-dot {
    display: inline-block;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: #6d6d6d;
    transition: background 0.3s ease, box-shadow 0.3s ease;
  }
  .status-dot.connected {
    background: #22c55e;
    box-shadow: 0 0 6px rgba(34, 197, 94, 0.5);
  }
  .shortcut-hint {
    opacity: 0.7;
  }
</style>
