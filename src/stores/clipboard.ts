import { writable, derived } from 'svelte/store';
import { invoke } from '@tauri-apps/api/core';
export const feLog = (msg: string) => { if (typeof window !== 'undefined') invoke('fe_log', { message: msg.slice(0, 300) }).catch(() => {}); };
import { listen } from '@tauri-apps/api/event';
import type { ClipboardItem, Settings, ContentCategory } from '../types';

// ── Core state ──
export const history = writable<ClipboardItem[]>([]);
export const selectedIndex = writable<number>(-1);
export const searchQuery = writable<string>('');
export const currentCategory = writable<ContentCategory>('all');
export const settingsOpen = writable<boolean>(false);
export const helperConnected = writable<boolean>(false);
export const toastMessage = writable<string>('');
export const zoomLevel = writable<number>(1.0);
export const settingsData = writable<Settings>({
  close_to_tray: true,
  zoom_level: 1.0,
  hotkey: 'Ctrl+Shift+V',
  auto_start: false,
  silent_start: true,
  double_tap_key: '',
  retention_days: 3,
  window_width: 400,
  window_height: 600,
  window_user_resized: false,
});

// ── Derived: filtered history ──
export const filteredHistory = derived(
  [history, searchQuery, currentCategory],
  ([hist, query, cat]) => {
    let items = hist;
    if (cat !== 'all') {
      items = items.filter(item => item.content_type === cat);
    }
    if (query) {
      const q = query.toLowerCase();
      items = items.filter(item => item.content.toLowerCase().includes(q));
    }
    return items;
  }
);

// ── Toast helper ──
let toastTimer: ReturnType<typeof setTimeout>;
export function showToast(msg: string) {
  toastMessage.set(msg);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toastMessage.set(''), 2000);
}

// ── Init: load history + settings + listen for events ──
export async function initClipboard() {
  try {
    const s = await invoke<Settings>('get_settings');
    feLog("loaded retention_days=" + s.retention_days);
    settingsData.set(s);
    zoomLevel.set(s.zoom_level);
  } catch (e) {
    console.error('Failed to load settings:', e);
  }

  try {
    const items = await invoke<ClipboardItem[]>('get_history');
    history.set(items);
  } catch (e) {
    console.error('Failed to load history:', e);
  }

  await listen<ClipboardItem[]>('clipboard-changed', (event) => {
    const top5 = event.payload;
    history.update(h => {
      const merged = [...top5, ...h.filter(hi => !top5.find(t => t.id === hi.id))];
      return merged.slice(0, 500);
    });
  });

  // Full-list replacement: used by tray "clear" (empty payload) and by the
  // hourly retention cleanup (full remaining list). The incremental
  // `clipboard-changed` event only carries the top 5, so it can neither clear
  // the view nor convey deletions beyond the head — hence this separate event.
  await listen<ClipboardItem[]>('history-replace', (event) => {
    history.set(event.payload);
    imageCache.clear();
  });

  // A number-key quick-paste (1-9) asked the backend to float the just-used
  // item to the top. Reorder the local store to match — single source of truth
  // lives in the backend (persisted order), this just mirrors it.
  await listen<number>('item-moved-to-top', (event) => {
    const id = event.payload;
    history.update(h => {
      const i = h.findIndex(x => x.id === id);
      if (i <= 0) return h;
      const nh = h.slice();
      const [it] = nh.splice(i, 1);
      nh.unshift(it);
      return nh;
    });
  });

  await listen<boolean>('helper-status', (event) => {
    helperConnected.set(event.payload);
  });

  await listen('open-settings', () => {
    settingsOpen.set(true);
    refreshSettings();
  });
}

export async function refreshSettings() {
  try {
    const s = await invoke<Settings>('get_settings');
      feLog("refreshSettings retention_days=" + s.retention_days);
settingsData.set(s);
    zoomLevel.set(s.zoom_level);
  } catch (e) {
    console.error('Failed to refresh settings:', e);
  }
}

// ── IPC wrappers ──
export async function copyItem(id: number): Promise<void> {
  return invoke('copy_to_clipboard', { id });
}

// Float an item to the top of the list. Only the number-key quick-paste path
// calls this; other copy actions intentionally leave order unchanged.
export async function moveToTop(id: number): Promise<void> {
  return invoke('move_to_top', { id });
}

// Simple in-memory cache for loaded image data URLs. Prevents redundant IPC
// calls when list items are re-mounted during scrolling.
const imageCache = new Map<number, string>();
const IMAGE_CACHE_MAX = 50;

// Load an item's image as a base64 data URL on demand (images are stored as
// external files on the backend, not inlined into history JSON).
export async function getImageData(id: number): Promise<string | null> {
  const cached = imageCache.get(id);
  if (cached !== undefined) return cached;
  const result = await invoke<string | null>('get_image_data', { id });
  if (result) {
    if (imageCache.size >= IMAGE_CACHE_MAX) {
      const oldest = imageCache.keys().next().value;
      if (oldest !== undefined) imageCache.delete(oldest);
    }
    imageCache.set(id, result);
  }
  return result;
}

export async function deleteItem(id: number): Promise<void> {
  await invoke('delete_item', { id });
  history.update(h => h.filter(i => i.id !== id));
  imageCache.delete(id);
}

export async function clearHistory(): Promise<void> {
  await invoke('clear_history');
  history.set([]);
  imageCache.clear();
}

export async function getSettings(): Promise<Settings> {
  return invoke('get_settings');
}

export async function updateSettings(partial: Partial<Settings>): Promise<Settings> {
  return invoke('update_settings', { partial });
}

export async function validateHotkey(hotkey: string): Promise<boolean> {
  return invoke('validate_hotkey', { hotkey });
}

export async function toggleAutostart(enable: boolean): Promise<void> {
  return invoke('toggle_autostart', { enable });
}

export async function simulatePaste(): Promise<void> {
  return invoke('simulate_paste_cmd');
}

// ── Type helpers ──
export function getTypeLabel(type: string): string {
  const labels: Record<string, string> = {
    link: '链接', text: '文本', short: '短文本', image: '图片', rich: '富文本',
  };
  return labels[type] || '文本';
}

export function getTypeClass(type: string): string {
  const classes: Record<string, string> = {
    link: 'type-link', text: 'type-text', short: 'type-short', image: 'type-image', rich: 'type-rich',
  };
  return classes[type] || '';
}

export function escapeHtml(text: string): string {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

import DOMPurify from 'dompurify';

// Sanitize clipboard-sourced HTML before rendering it in the Tauri webview.
// DOMPurify strips scripts, inline event handlers (on*), and javascript:/
// data:script/vbscript: URLs by default — the same surface the old hand-rolled
// sanitizer tried to cover, but robust against mXSS bypasses that a blocklist
// approach misses. The CSP (default-src 'self', no unsafe-inline scripts) is a
// second layer; this is the first.
export function sanitizeHtml(html: string): string {
  return DOMPurify.sanitize(html, {
    FORBID_TAGS: ['style', 'iframe', 'object', 'embed', 'form', 'input', 'button', 'select', 'textarea', 'link', 'meta', 'base'],
    FORBID_ATTR: ['style'],
  });
}
