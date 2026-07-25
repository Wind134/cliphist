<script lang="ts">
  import { getVersion } from '@tauri-apps/api/app';
  import {
    settingsOpen, settingsData, showToast,
    updateSettings, validateHotkey, helperConnected, feLog,
  } from '../stores/clipboard';

  let hotkeyInput = $state('');
  let hotkeyError = $state('');
  let retentionSelect: HTMLSelectElement;
  let doubleTapSelect: HTMLSelectElement;
  let appVersion = $state('…');

  // Load the real, packaging-derived version (from tauri.conf.json) so the
  // About section always shows what was actually built — not a hand-maintained constant.
  $effect(() => {
    getVersion().then(v => { appVersion = v; }).catch(() => { appVersion = '未知'; });
  });

  function close() {
    settingsOpen.set(false);
  }

  async function onToggleCloseToTray(e: Event) {
    const checked = (e.target as HTMLInputElement).checked;
    try {
      await updateSettings({ close_to_tray: checked });
      settingsData.update(s => ({ ...s, close_to_tray: checked }));
      showToast('设置已保存');
    } catch (err) {
      showToast('保存失败: ' + String(err));
    }
  }

  async function onToggleAutoStart(e: Event) {
    const checked = (e.target as HTMLInputElement).checked;
    try {
      const saved = await updateSettings({ auto_start: checked });
      settingsData.set(saved);
      showToast('设置已保存');
    } catch (err) {
      (e.target as HTMLInputElement).checked = !checked;
      showToast('保存失败: ' + String(err));
    }
  }

  async function onToggleSilentStart(e: Event) {
    const checked = (e.target as HTMLInputElement).checked;
    try {
      await updateSettings({ silent_start: checked });
      settingsData.update(s => ({ ...s, silent_start: checked }));
      showToast('设置已保存');
    } catch (err) {
      showToast('保存失败: ' + String(err));
    }
  }

  async function zoomDown() {
    const current = $settingsData.zoom_level * 100;
    if (current > 50) {
      const newZoom = (current - 10) / 100;
      try {
        await updateSettings({ zoom_level: newZoom });
        settingsData.update(s => ({ ...s, zoom_level: newZoom }));
        showToast('缩放已调整');
      } catch (err) {
        console.error('Failed to save zoom:', err);
      }
    }
  }

  async function zoomUp() {
    const current = $settingsData.zoom_level * 100;
    if (current < 200) {
      const newZoom = (current + 10) / 100;
      try {
        await updateSettings({ zoom_level: newZoom });
        settingsData.update(s => ({ ...s, zoom_level: newZoom }));
        showToast('缩放已调整');
      } catch (err) {
        console.error('Failed to save zoom:', err);
      }
    }
  }

  async function onHotkeyChange() {
    hotkeyError = '';
    if (!hotkeyInput) return;

    try {
      const valid = await validateHotkey(hotkeyInput);
      if (!valid) {
        hotkeyError = '格式错误，例如：Ctrl+Shift+V';
        return;
      }
      await updateSettings({ hotkey: hotkeyInput });
      settingsData.update(s => ({ ...s, hotkey: hotkeyInput }));
      showToast('快捷键已生效');
    } catch (err) {
      showToast('保存失败: ' + String(err));
    }
  }

  async function onDoubleTapChange(e: Event) {
    const val = (e.target as HTMLSelectElement).value;
    try {
      await updateSettings({ double_tap_key: val });
      settingsData.update(s => ({ ...s, double_tap_key: val }));
      showToast('双击快捷键已保存');
    } catch (err) {
      showToast('保存失败: ' + String(err));
    }
  }

  async function onRetentionChange(e: Event) {
    feLog("onRetentionChange raw=" + (e.target as HTMLSelectElement).value);
    const val = parseInt((e.target as HTMLSelectElement).value);
    try {
      await updateSettings({ retention_days: val });
      settingsData.update(s => ({ ...s, retention_days: val }));
      showToast('设置已保存');
    } catch (err) {
      showToast('保存失败: ' + String(err));
    }
  }

  function onPanelKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault();
      close();
    }
  }

  $effect(() => {
    if ($settingsOpen) {
      hotkeyInput = $settingsData.hotkey;
      hotkeyError = '';
    }
  });
  $effect(() => {
    if (retentionSelect && $settingsData.retention_days !== undefined) {
      retentionSelect.value = String($settingsData.retention_days);
    }
  });
  $effect(() => {
    if (doubleTapSelect && $settingsData.double_tap_key !== undefined) {
      doubleTapSelect.value = String($settingsData.double_tap_key);
    }
  });
</script>

<svelte:window onkeydown={onPanelKeydown} />


<div class="settings-panel">
  <header class="settings-header">
    <span class="settings-title">设置</span>
    <button class="btn-close" onclick={close} aria-label="关闭设置">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <line x1="18" y1="6" x2="6" y2="18"></line>
            <line x1="6" y1="6" x2="18" y2="18"></line>
          </svg>
        </button>
      </header>
      <div class="settings-body">
        <!-- Close to tray -->
        <div class="settings-item">
          <div class="settings-item-info">
            <span class="settings-item-label">关闭时最小化到托盘</span>
            <span class="settings-item-desc">关闭窗口时程序继续在后台运行</span>
          </div>
          <label class="toggle-switch">
            <input type="checkbox" checked={$settingsData.close_to_tray} onchange={onToggleCloseToTray} />
            <span class="toggle-slider"></span>
          </label>
        </div>

        <!-- Silent start -->
        <div class="settings-item">
          <div class="settings-item-info">
            <span class="settings-item-label">静默启动</span>
            <span class="settings-item-desc">启动时自动隐藏到托盘后台运行</span>
          </div>
          <label class="toggle-switch">
            <input type="checkbox" checked={$settingsData.silent_start} onchange={onToggleSilentStart} />
            <span class="toggle-slider"></span>
          </label>
        </div>

        <!-- Auto start -->
        <div class="settings-item">
          <div class="settings-item-info">
            <span class="settings-item-label">开机自动启动</span>
            <span class="settings-item-desc">系统启动时自动运行 ClipHist</span>
          </div>
          <label class="toggle-switch">
            <input type="checkbox" checked={$settingsData.auto_start} onchange={onToggleAutoStart} />
            <span class="toggle-slider"></span>
          </label>
        </div>

        <!-- Zoom -->
        <div class="settings-item">
          <div class="settings-item-info">
            <span class="settings-item-label">窗口缩放</span>
            <span class="settings-item-desc">调整界面显示大小</span>
          </div>
          <div class="zoom-control">
            <button class="zoom-btn" onclick={zoomDown}>−</button>
            <span class="zoom-value">{Math.round($settingsData.zoom_level * 100)}%</span>
            <button class="zoom-btn" onclick={zoomUp}>+</button>
          </div>
        </div>

        <!-- Hotkey -->
        <div class="settings-item">
          <div class="settings-item-info">
            <span class="settings-item-label">全局快捷键</span>
            <span class="settings-item-desc">唤醒窗口的快捷键</span>
            {#if hotkeyError}
              <span class="settings-item-error">{hotkeyError}</span>
            {/if}
          </div>
          <input
            type="text"
            class="hotkey-input"
            placeholder="Ctrl+Shift+V"
            bind:value={hotkeyInput}
            onchange={onHotkeyChange}
          />
        </div>

        <!-- Double tap key -->
        <div class="settings-item">
          <div class="settings-item-info">
            <span class="settings-item-label">双击快捷键</span>
            <span class="settings-item-desc">快速双击指定键唤醒窗口</span>
            {#if $settingsData.double_tap_key}
              <span class="settings-item-note" class:authorized={$helperConnected}>
                {$helperConnected ? '已授权' : 'Linux 下首次使用需授权'}
              </span>
            {/if}
          </div>
          <select class="hotkey-input" bind:this={doubleTapSelect} value={$settingsData.double_tap_key} onchange={onDoubleTapChange}>
            <option value="">禁用</option>
            <option value="Ctrl">Ctrl</option>
            <option value="Shift">Shift</option>
            <option value="Alt">Alt</option>
          </select>
        </div>

        <!-- Retention -->
        <div class="settings-item">
          <div class="settings-item-info">
            <span class="settings-item-label">历史记录保存时长</span>
            <span class="settings-item-desc">超过设定时间的记录将自动清理</span>
          </div>
          <select class="hotkey-input" bind:this={retentionSelect} value={$settingsData.retention_days} onchange={onRetentionChange}>
            <option value="1">1 天</option>
            <option value="3">3 天</option>
            <option value="7">7 天</option>
            <option value="30">30 天</option>
            <option value="0" title="保留全部记录，不自动清理">永久</option>
          </select>
        </div>

      <!-- About: shows the real, packaging-derived version -->
      <div class="settings-item about">
        <div class="settings-item-info">
          <span class="settings-item-label">关于 ClipHist</span>
          <span class="settings-item-desc">版本 {appVersion} · 剪贴板历史管理器</span>
        </div>
      </div>
    </div>
  </div>

<style>
  .settings-panel {
    display: flex;
    flex-direction: column;
    flex: 1;
    overflow: hidden;
  }
  .settings-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    height: 32px;
    padding: 0 8px 0 16px;
    background: var(--titlebar-bg);
    /*removed*/
    flex-shrink: 0;
  }
  .settings-title {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
  }
  .btn-close {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    border: none;
    background: transparent;
    color: var(--text-secondary);
    border-radius: 4px;
    cursor: pointer;
    transition: all 0.15s;
  }
  .btn-close:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }
  .settings-body {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .settings-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px;
    background: var(--bg-secondary);
    border-radius: 8px;
    border: none; box-shadow: 0 1px 3px rgba(0,0,0,0.06);
  }
  .settings-item-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
    flex: 1;
  }
  .settings-item-label {
    font-size: 13px;
    font-weight: 500;
    color: var(--text-primary);
  }
  .settings-item-desc {
    font-size: 11px;
    color: var(--text-tertiary);
  }
  .settings-item-error {
    font-size: 11px;
    color: #dc2626;
    margin-top: 2px;
  }
  .settings-item-note {
    font-size: 11px;
    color: var(--text-tertiary);
    margin-top: 2px;
  }
  .settings-item-note.authorized {
    color: #22c55e;
  }
  .about {
    background: transparent;
    box-shadow: none;
  }
  .toggle-switch {
    position: relative;
    display: inline-block;
    width: 40px;
    height: 22px;
    flex-shrink: 0;
  }
  .toggle-switch input {
    opacity: 0;
    width: 0;
    height: 0;
  }
  .toggle-slider {
    position: absolute;
    cursor: pointer;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background: var(--bg-hover);
    border-radius: 11px;
    transition: 0.2s;
  }
  .toggle-slider::before {
    content: '';
    position: absolute;
    height: 16px;
    width: 16px;
    left: 3px;
    bottom: 3px;
    background: white;
    border-radius: 50%;
    transition: 0.2s;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.2);
  }
  .toggle-switch input:checked + .toggle-slider {
    background: #4F46E5;
  }
  .toggle-switch input:checked + .toggle-slider::before {
    transform: translateX(18px);
  }
  .zoom-control {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .zoom-btn {
    width: 28px;
    height: 28px;
    border: 1px solid var(--border);
    background: var(--bg-tertiary);
    border-radius: 4px;
    cursor: pointer;
    font-size: 16px;
    color: var(--text-primary);
    display: flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
  }
  .zoom-btn:hover {
    background: var(--bg-hover);
  }
  .zoom-value {
    font-size: 13px;
    min-width: 45px;
    text-align: center;
    color: var(--text-primary);
  }
  .hotkey-input {
    padding: 6px 10px;
    border: 1px solid var(--border);
    border-radius: 4px;
    font-size: 12px;
    background: var(--bg-tertiary);
    color: var(--text-primary);
    width: 120px;
    text-align: center;
    font-family: inherit;
  }
  .hotkey-input:focus {
    outline: none;
    border-color: var(--accent);
  }
</style>
