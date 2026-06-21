<script lang="ts">
  import type { ClipboardItem } from '../types';
  import { getTypeLabel, getTypeClass, escapeHtml, stripScripts } from '../stores/clipboard';

  let { item, index, isSelected }: {
    item: ClipboardItem;
    index: number;
    isSelected: boolean;
  } = $props();

  const typeIcon: Record<string, string> = {
    link: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"></path><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"></path></svg>`,
    text: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline><line x1="16" y1="13" x2="8" y2="13"></line><line x1="16" y1="17" x2="8" y2="17"></line></svg>`,
    short: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="21" y1="10" x2="3" y2="10"></line><line x1="21" y1="6" x2="3" y2="6"></line><line x1="21" y1="14" x2="3" y2="14"></line><line x1="21" y1="18" x2="3" y2="18"></line></svg>`,
    image: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><circle cx="8.5" cy="8.5" r="1.5"></circle><polyline points="21 15 16 10 5 21"></polyline></svg>`,
    rich: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline><path d="M9 13h2l1 3 2-6 1 3h2"></path></svg>`,
  };
</script>

<div
  class="history-item"
  class:selected={isSelected}
  role="option"
  aria-selected={isSelected}
  data-id={item.id}
>
  {#if index < 9}
    <div class="item-index">{index + 1}</div>
  {/if}
  <div class="item-header">
    <div class="item-type {getTypeClass(item.content_type)}">
      <span class="item-type-icon">{@html typeIcon[item.content_type] || typeIcon.text}</span>
      <span>{getTypeLabel(item.content_type)}</span>
    </div>
    <div class="item-header-right">
      <span class="item-time">{item.timestamp}</span>
      <div class="item-actions">
        <button class="item-action-btn copy" title="复制" data-action="copy" data-id={item.id}>
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
            <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
          </svg>
        </button>
        <button class="item-action-btn delete" title="删除" data-action="delete" data-id={item.id}>
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <polyline points="3 6 5 6 21 6"></polyline>
            <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path>
          </svg>
        </button>
      </div>
    </div>
  </div>
  <div class="item-preview">
    {#if item.content_type === 'image' && item.image_data}
      <img class="item-image" src="data:image/png;base64,{item.image_data}" alt="clipboard image" />
    {:else if item.content_type === 'rich' && item.html_content}
      <div class="rich-preview">{@html stripScripts(item.html_content)}</div>
    {:else}
      {escapeHtml(item.preview)}
    {/if}
  </div>
  <div class="item-meta">
    <span class="item-length">
      {item.content_type === 'image' ? `${item.image_width}×${item.image_height} px` : `${item.char_count} 字符`}
    </span>
  </div>
</div>

<style>
  .history-item {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 12px 14px 12px 36px;
    background: var(--bg-secondary);
    border-radius: 8px;
    cursor: pointer;
    transition: all 0.15s;
    border: 1px solid transparent;
    position: relative;
    margin-bottom: 8px;
  }
  .history-item:hover {
    background: var(--bg-hover);
    box-shadow: 0 1px 3px rgba(0,0,0,0.08); border-color: transparent;
  }
  .history-item.selected {
    background: var(--bg-hover);
    box-shadow: 0 0 0 1px var(--accent); border-color: transparent;
  }
  .item-index {
    position: absolute;
    left: 8px;
    top: 50%;
    transform: translateY(-50%);
    width: 18px;
    height: 18px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 10px;
    font-weight: 600;
    color: var(--text-tertiary);
    background: var(--bg-hover);
    border-radius: 4px;
    pointer-events: none;
  }
  .item-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .item-header-right {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .item-type {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 11px;
    color: var(--text-tertiary);
  }
  .item-type-icon {
    opacity: 0.6;
  }
  .item-time {
    font-size: 11px;
    color: var(--text-tertiary);
  }
  .item-preview {
    font-size: 13px;
    color: var(--text-primary);
    line-height: 1.4;
    word-break: break-all;
    overflow: hidden;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
  }
  .item-image {
    max-width: 100%;
    max-height: 120px;
    border-radius: 4px;
    object-fit: contain;
    display: block;
  }
  .rich-preview {
    font-size: 12px;
    line-height: 1.4;
    overflow: hidden;
    display: -webkit-box;
    -webkit-line-clamp: 3;
    -webkit-box-orient: vertical;
    word-break: break-all;
  }
  .item-meta {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-top: 2px;
  }
  .item-length {
    font-size: 10px;
    color: var(--text-tertiary);
  }
  .item-actions {
    display: flex;
    gap: 4px;
    opacity: 0;
    pointer-events: none;
    transition: opacity 0.15s;
  }
  .history-item:hover .item-actions {
    opacity: 1;
    pointer-events: auto;
  }
  .item-action-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    border: none;
    background: var(--bg-secondary);
    color: var(--text-secondary);
    border-radius: 4px;
    cursor: pointer;
    transition: all 0.15s;
    box-shadow: 0 1px 3px var(--shadow);
  }
  .item-action-btn:hover {
    background: var(--bg-active);
    color: var(--text-primary);
  }
  .item-action-btn.delete:hover {
    background: #fde7e9;
    color: #c42b1c;
  }
  .type-link { color: var(--accent); }
  .type-text { color: #107c10; }
  .type-short { color: #8764b8; }
  .type-rich { color: #e11d48; }
</style>
