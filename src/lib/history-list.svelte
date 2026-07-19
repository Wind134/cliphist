<script lang="ts">
  import { onMount } from 'svelte';
  import { get } from 'svelte/store';
  import { invoke } from '@tauri-apps/api/core';
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import { confirm } from '@tauri-apps/plugin-dialog';
  import {
    filteredHistory, selectedIndex, searchQuery, currentCategory,
    history, copyItem, moveToTop, deleteItem, clearHistory, showToast, settingsData,
    settingsOpen, refreshSettings,
  } from '../stores/clipboard';
  import CategoryTabs from './category-tabs.svelte';
  import HistoryItem from './history-item.svelte';

  let searchInput: HTMLInputElement;
  let listContainer: HTMLElement;
    function handleSearchInput(e: Event) {
    const val = (e.target as HTMLInputElement).value;
    searchQuery.set(val);
    selectedIndex.set(-1);
  }

  function clearSearch() {
    searchQuery.set('');
    selectedIndex.set(-1);
    if (searchInput) searchInput.value = '';
  }

  function handleItemClick(e: MouseEvent) {
    const target = e.target as HTMLElement;

    // action buttons
    const actionBtn = target.closest('[data-action]') as HTMLElement;
    if (actionBtn) {
      e.stopPropagation();
      const action = actionBtn.dataset.action;
      const id = parseInt(actionBtn.dataset.id || '0');
      if (action === 'copy') {
        copyItem(id).then(() => showToast('已复制到剪贴板')).catch(err => showToast('复制失败: ' + err));
      } else if (action === 'delete') {
        deleteItem(id).then(() => showToast('已删除')).catch(err => showToast('删除失败: ' + err));
      }
      return;
    }

    // click on item body = copy
    const itemEl = target.closest('.history-item') as HTMLElement;
    if (itemEl) {
      const id = parseInt(itemEl.dataset.id || '0');
      const idx = $filteredHistory.findIndex(it => it.id === id);
      if (idx >= 0) selectedIndex.set(idx);
    }
  }

  function handleDblClick(e: MouseEvent) {
    const itemEl = (e.target as HTMLElement).closest('.history-item') as HTMLElement;
    if (itemEl) {
      const id = parseInt(itemEl.dataset.id || '0');
      copyItem(id)
        .then(() => {
          showToast('已复制到剪贴板');
          if (get(settingsData).close_to_tray) {
            getCurrentWindow().hide();
          }
        })
        .catch(err => showToast('复制失败: ' + err));
    }
  }

  function moveSelection(delta: number) {
    const filtered = $filteredHistory;
    let idx = $selectedIndex;
    if (filtered.length === 0) return;

    if (idx === -1 && delta === 1) {
      idx = 0;
    } else {
      idx = Math.max(0, Math.min(filtered.length - 1, idx + delta));
    }
    selectedIndex.set(idx);

    // scroll into view
    setTimeout(() => {
      const el = listContainer?.querySelector('.history-item.selected');
      if (el) el.scrollIntoView({ block: 'nearest' });
    }, 0);
  }

  async function handleEnter() {
    const filtered = $filteredHistory;
    const idx = $selectedIndex;
    if (idx >= 0 && idx < filtered.length) {
      try {
        await copyItem(filtered[idx].id);
        showToast('已复制到剪贴板');
      } catch (err) {
        showToast('复制失败: ' + String(err));
      }
    }
  }

  async function handleQuickPaste(num: number) {
    const filtered = $filteredHistory;
    const idx = num - 1;
    if (idx < filtered.length) {
      try {
        const id = filtered[idx].id;
        await copyItem(id);
        // 数字键快速粘贴：把这条浮到列表最前（其它复制动作不调整顺序）
        await moveToTop(id);
        await getCurrentWindow().hide();
        await new Promise(r => setTimeout(r, 200));
        await invoke('simulate_paste_cmd');
      } catch (err) {
        showToast('输入失败: ' + String(err));
      }
    }
  }

  function handleSearchKeydown(e: KeyboardEvent) {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      moveSelection(1);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      moveSelection(-1);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      handleEnter();
    } else if (e.key === 'Escape') {
      searchInput.blur();
    }
  }

  function openSettings() {
    settingsOpen.set(true);
    refreshSettings();
  }

  async function handleClear() {
    const ok = await confirm('确定要清空所有历史记录吗？', {
      title: '清空历史',
      kind: 'warning',
    });
    if (!ok) return;
    await clearHistory();
    showToast('已清空');
  }

  function onGlobalKeydown(e: KeyboardEvent) {
    // don't intercept when typing text in search
    if (document.activeElement === searchInput) return;

    const num = parseInt(e.key);
    if (num >= 1 && num <= 9) {
      if (document.activeElement === searchInput) {
        searchInput.blur();
      }
      e.preventDefault();
      handleQuickPaste(num);
    }
  }

  onMount(() => {
    document.addEventListener('keydown', onGlobalKeydown);
    return () => document.removeEventListener('keydown', onGlobalKeydown);
  });
</script>

<div class="search-container">
  <CategoryTabs />
  <div class="search-box">
    <svg class="search-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
      <circle cx="11" cy="11" r="8"></circle>
      <line x1="21" y1="21" x2="16.65" y2="16.65"></line>
    </svg>
    <input
      type="text"
      bind:this={searchInput}
      placeholder="搜索剪贴板历史..."
      autocomplete="off"
      oninput={handleSearchInput}
      onkeydown={handleSearchKeydown}
    />
    <button class="search-clear" class:visible={$searchQuery.length > 0} onclick={clearSearch} aria-label="清除搜索">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <line x1="18" y1="6" x2="6" y2="18"></line>
          <line x1="6" y1="6" x2="18" y2="18"></line>
        </svg>
      </button>
  </div>
</div>

<div class="history-toolbar">
  <span class="item-count">{$history.length} 条记录</span>
  <div class="toolbar-actions">
    <button class="btn-icon" onclick={openSettings} title="设置">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <circle cx="12" cy="12" r="3"></circle>
        <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"></path>
      </svg>
    </button>
    <button class="btn-icon" onclick={handleClear} title="清空历史">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <polyline points="3 6 5 6 21 6"></polyline>
        <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path>
      </svg>
    </button>
  </div>
</div>

<main class="content" bind:this={listContainer}>
  {#if $filteredHistory.length === 0 && $history.length === 0}
    <div class="empty-state">
      <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" opacity="0.3">
        <path d="M9 5H7a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-2"></path>
        <rect x="9" y="3" width="6" height="4" rx="2"></rect>
      </svg>
      <p>暂无剪贴板记录</p>
      <p class="empty-hint">复制内容后会显示在这里</p>
    </div>
  {:else if $filteredHistory.length === 0}
    <div class="empty-state">
      <p>没有找到匹配的结果</p>
    </div>
  {:else}
    <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
    <div class="history-list" onclick={handleItemClick} ondblclick={handleDblClick} role="listbox">
      {#each $filteredHistory as item, i (item.id)}
          <HistoryItem item={item} index={i} isSelected={i === $selectedIndex} />
      {/each}
    </div>
  {/if}
</main>

<style>
  .search-container {
    padding: 8px 12px 6px;
    background: var(--bg-secondary);
    display: flex;
    flex-direction: column;
    gap: 6px;
    /*removed*/
  }
  .search-box {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 12px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border);
    border-radius: 6px;
    transition: all 0.2s;
  }
  .search-box:focus-within {
    border-color: var(--accent);
    box-shadow: 0 0 0 2px rgba(61, 174, 233, 0.15);
  }
  .search-icon {
    color: var(--text-tertiary);
    flex-shrink: 0;
  }
  .search-box input {
    flex: 1;
    border: none;
    background: transparent;
    font-size: 13px;
    color: var(--text-primary);
    outline: none;
  }
  .search-box input::placeholder {
    color: var(--text-tertiary);
  }
  .search-clear {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
    border: none;
    background: var(--bg-hover);
    color: var(--text-tertiary);
    border-radius: 50%;
    cursor: pointer;
    transition: all 0.15s;
    visibility: hidden;
    opacity: 0;
  }
  .search-clear.visible {
    visibility: visible;
    opacity: 1;
  }
  .search-clear:hover {
    background: var(--bg-active);
    color: var(--text-primary);
  }
  .history-toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 4px 12px;
    background: var(--bg-secondary);
    /*removed*/
  }
  .item-count {
    font-size: 11px;
    color: var(--text-tertiary);
  }
  .toolbar-actions {
    display: flex;
    align-items: center;
    gap: 4px;
  }
  .btn-icon {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    border: none;
    background: transparent;
    color: var(--text-secondary);
    border-radius: 4px;
    cursor: pointer;
    transition: all 0.15s;
  }
  .btn-icon:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }
  .content {
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    padding: 8px 12px;
  }
  .history-list {
    display: flex;
    flex-direction: column;
  }
  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    height: 100%;
    min-height: 200px;
    gap: 12px;
    color: var(--text-tertiary);
  }
  .empty-state p {
    font-size: 13px;
  }
  .empty-hint {
    font-size: 11px;
    color: var(--text-tertiary);
    opacity: 0.7;
  }
</style>
