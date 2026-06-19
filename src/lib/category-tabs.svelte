<script lang="ts">
  import { currentCategory } from '../stores/clipboard';

  const tabs: { cat: string; label: string; color: string }[] = [
    { cat: 'all', label: '全部', color: '#4F46E5' },
    { cat: 'image', label: '图片', color: '#059669' },
    { cat: 'text', label: '文本', color: '#2563EB' },
    { cat: 'link', label: '链接', color: '#DC2626' },
    { cat: 'short', label: '短文本', color: '#7C3AED' },
    { cat: 'rich', label: '富文本', color: '#e11d48' },
  ];
</script>

<div class="category-tabs">
  {#each tabs as tab}
    <button
      class="cat-tab"
      class:active={$currentCategory === tab.cat}
      style={$currentCategory === tab.cat ? 'background:' + tab.color : ''}
      onclick={() => currentCategory.set(tab.cat)}
    >
      {tab.label}
    </button>
  {/each}
</div>

<style>
  .category-tabs {
    display: flex;
    gap: 4px;
    flex-wrap: wrap;
  }
  .cat-tab {
    padding: 4px 12px;
    border-radius: 6px;
    border: none;
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
    color: var(--text-secondary);
    background: var(--bg-tertiary);
  }
  .cat-tab:hover {
    color: var(--text-primary);
    background: var(--bg-hover);
  }
  .cat-tab.active {
    color: #fff;
    font-weight: 600;
  }
</style>
