const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

let history = [];
let searchQuery = '';
let selectedIndex = -1;
let currentCategory = 'all';

const historyList = document.getElementById('history-list');
const searchInput = document.getElementById('search-input');
const btnSearchClear = document.getElementById('btn-search-clear');
const itemCount = document.getElementById('item-count');
const btnClear = document.getElementById('btn-clear');
const btnMinimize = document.getElementById('btn-minimize');
const btnClose = document.getElementById('btn-close');
const statusText = document.getElementById('status-text');
const toast = document.getElementById('toast');

const TYPE_ICONS = {
  link: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"></path><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"></path></svg>`,
  text: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline><line x1="16" y1="13" x2="8" y2="13"></line><line x1="16" y1="17" x2="8" y2="17"></line></svg>`,
  short: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="21" y1="10" x2="3" y2="10"></line><line x1="21" y1="6" x2="3" y2="6"></line><line x1="21" y1="14" x2="3" y2="14"></line><line x1="21" y1="18" x2="3" y2="18"></line></svg>`,
  image: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><circle cx="8.5" cy="8.5" r="1.5"></circle><polyline points="21 15 16 10 5 21"></polyline></svg>`,
};

function getTypeLabel(type) {
  const labels = { link: '链接', text: '文本', short: '短文本', image: '图片' };
  return labels[type] || '文本';
}

function getTypeClass(type) {
  const classes = { link: 'type-link', text: 'type-text', short: 'type-short', image: 'type-image' };
  return classes[type] || '';
}

function renderHistory(itemsToRender) {
  if (itemsToRender.length === 0 && history.length === 0) {
    historyList.innerHTML = `
      <div class="empty-state">
        <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" opacity="0.3">
          <path d="M9 5H7a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-2"></path>
          <rect x="9" y="3" width="6" height="4" rx="2"></rect>
        </svg>
        <p>暂无剪贴板记录</p>
        <p class="empty-hint">复制内容后会显示在这里</p>
      </div>`;
    return;
  }

  if (itemsToRender.length === 0) {
    historyList.innerHTML = `
      <div class="empty-state">
        <p>没有找到匹配的结果</p>
      </div>`;
    return;
  }

  historyList.innerHTML = itemsToRender.map((item, idx) => `
    <div class="history-item" data-id="${item.id}" data-idx="${idx}">
      <div class="item-header">
        <div class="item-type ${getTypeClass(item.content_type)}">
          <span class="item-type-icon">${TYPE_ICONS[item.content_type] || TYPE_ICONS.text}</span>
          <span>${getTypeLabel(item.content_type)}</span>
        </div>
        <div style="display:flex;align-items:center;gap:8px;">
          <span class="item-time">${item.timestamp}</span>
          <div class="item-actions">
            <button class="item-action-btn copy" title="复制" data-action="copy" data-id="${item.id}">
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
                <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
              </svg>
            </button>
            <button class="item-action-btn delete" title="删除" data-action="delete" data-id="${item.id}">
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <polyline points="3 6 5 6 21 6"></polyline>
                <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path>
              </svg>
            </button>
          </div>
        </div>
      </div>
      <div class="item-preview">${item.content_type === 'image' && item.image_data
        ? `<img class="item-image" src="data:image/png;base64,${item.image_data}" alt="clipboard image" />`
        : escapeHtml(item.preview)}</div>
      <div class="item-meta">
        <span class="item-length">${item.content_type === 'image' ? `${item.image_width}×${item.image_height} px` : `${item.char_count} 字符`}</span>
      </div>
    </div>`).join('');
}

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

function getFilteredHistory() {
  let items = history;
  // Category filter
  if (currentCategory !== 'all') {
    items = items.filter(item => item.content_type === currentCategory);
  }
  // Search filter
  if (searchQuery) {
    const q = searchQuery.toLowerCase();
    items = items.filter(item => item.content.toLowerCase().includes(q));
  }
  return items;
}

function updateCount() {
  const count = history.length;
  itemCount.textContent = `${count} 条记录`;
}

async function copyItem(id) {
  const item = history.find(i => i.id === id);
  if (!item) return;
  try {
    await invoke('copy_to_clipboard', { content: item.content });
    showToast('已复制到剪贴板');
  } catch (e) {
    showToast('复制失败: ' + e);
  }
}

async function deleteItem(id) {
  try {
    await invoke('delete_item', { id });
    history = history.filter(i => i.id !== id);
    renderHistory(getFilteredHistory());
    updateCount();
    showToast('已删除');
  } catch (e) {
    showToast('删除失败: ' + e);
  }
}

async function clearAll() {
  if (!confirm('确定要清空所有历史记录吗？')) return;
  try {
    await invoke('clear_history');
    history = [];
    renderHistory([]);
    updateCount();
    showToast('已清空');
  } catch (e) {
    showToast('清空失败: ' + e);
  }
}

function showToast(msg) {
  toast.textContent = msg;
  toast.style.display = 'block';
  setTimeout(() => { toast.style.display = 'none'; }, 2000);
}

function moveSelection(delta) {
  const filtered = getFilteredHistory();
  if (filtered.length === 0) return;

  if (selectedIndex === -1 && delta === 1) {
    selectedIndex = 0;
  } else {
    selectedIndex = Math.max(0, Math.min(filtered.length - 1, selectedIndex + delta));
  }

  document.querySelectorAll('.history-item').forEach((el, i) => {
    el.style.background = i === selectedIndex ? 'var(--bg-hover)' : '';
  });

  const selected = document.querySelector(`.history-item[data-idx="${selectedIndex}"]`);
  if (selected) selected.scrollIntoView({ block: 'nearest' });
}

async function loadHistory() {
  try {
    history = await invoke('get_history');
    renderHistory(history);
    updateCount();
  } catch (e) {
    console.error('Failed to load history:', e);
  }
}

async function init() {
  await loadHistory();

  listen('clipboard-changed', (event) => {
    if (searchQuery) return;
    const top5 = event.payload;
    history = [...top5, ...history.filter(h => !top5.find(t => t.id === h.id))];
    history = history.slice(0, 500);
    // Only re-render if not filtering by category (or if new item matches current category)
    if (currentCategory === 'all' || top5.some(t => t.content_type === currentCategory)) {
      renderHistory(getFilteredHistory());
    }
    updateCount();
  });

  searchInput.addEventListener('input', (e) => {
    searchQuery = e.target.value;
    btnSearchClear.style.display = searchQuery ? 'flex' : 'none';
    selectedIndex = -1;
    renderHistory(getFilteredHistory());
  });

  btnSearchClear.addEventListener('click', () => {
    searchQuery = '';
    searchInput.value = '';
    btnSearchClear.style.display = 'none';
    selectedIndex = -1;
    renderHistory(getFilteredHistory());
  });

  // Category tab switching
  document.querySelectorAll('.cat-tab').forEach(tab => {
    tab.addEventListener('click', () => {
      document.querySelectorAll('.cat-tab').forEach(t => t.classList.remove('active'));
      tab.classList.add('active');
      currentCategory = tab.dataset.cat;
      selectedIndex = -1;
      renderHistory(getFilteredHistory());
    });
  });

  historyList.addEventListener('click', (e) => {
    const btn = e.target.closest('[data-action]');
    if (btn) {
      e.stopPropagation();
      const action = btn.dataset.action;
      const id = parseInt(btn.dataset.id);
      if (action === 'copy') copyItem(id);
      else if (action === 'delete') deleteItem(id);
      return;
    }

    const item = e.target.closest('.history-item');
    if (item) {
      const id = parseInt(item.dataset.id);
      copyItem(id);
    }
  });

  historyList.addEventListener('dblclick', (e) => {
    const item = e.target.closest('.history-item');
    if (item) {
      const id = parseInt(item.dataset.id);
      copyItem(id);
    }
  });

  btnClear.addEventListener('click', clearAll);

  btnMinimize.addEventListener('click', () => {
    const { getCurrentWindow } = window.__TAURI__.window;
    getCurrentWindow().minimize();
  });

  btnClose.addEventListener('click', () => {
    const { getCurrentWindow } = window.__TAURI__.window;
    getCurrentWindow().hide();
  });

  searchInput.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      moveSelection(1);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      moveSelection(-1);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      const filtered = getFilteredHistory();
      if (selectedIndex >= 0 && selectedIndex < filtered.length) {
        copyItem(filtered[selectedIndex].id);
      }
    } else if (e.key === 'Escape') {
      searchInput.blur();
    }
  });
}

window.addEventListener('DOMContentLoaded', init);
