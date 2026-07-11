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
    applyZoom(s.zoom_level);
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
    applyZoom(s.zoom_level);
  } catch (e) {
    console.error('Failed to refresh settings:', e);
  }
}

// ── IPC wrappers ──
export async function copyItem(id: number): Promise<void> {
  return invoke('copy_to_clipboard', { id });
}

export async function deleteItem(id: number): Promise<void> {
  await invoke('delete_item', { id });
  history.update(h => h.filter(i => i.id !== id));
}

export async function clearHistory(): Promise<void> {
  await invoke('clear_history');
  history.set([]);
}

export async function searchHistory(query: string): Promise<ClipboardItem[]> {
  return invoke('search_history', { query });
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

// ── Zoom ──
export function applyZoom(zoom: number) {
  document.documentElement.style.zoom = String(zoom);
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

export function stripScripts(html: string): string {
  const div = document.createElement('div');
  div.innerHTML = html;
  const dangerous = div.querySelectorAll(
    'script, style, iframe, object, embed, form, input, button, select, textarea, link, meta, base'
  );
  dangerous.forEach(el => el.remove());
  // Strip every inline event handler (on*) so no clipboard-sourced HTML can
  // run scripts in the Tauri webview. A blocklist of specific on* names is
  // unsafe because there are dozens of valid event-handler attributes.
  const SAFE_URL_ATTRS: Record<string, string[]> = {
    a: ['href'],
    img: ['src'],
  };
  div.querySelectorAll('*').forEach(el => {
    // remove all on* attributes
    Array.from(el.attributes).forEach(attr => {
      if (/^on/i.test(attr.name)) el.removeAttribute(attr.name);
    });
    // sanitize url-bearing attributes: drop javascript:/data:script, keep safe ones
    const allow = SAFE_URL_ATTRS[el.tagName.toLowerCase()] ?? [];
    Array.from(el.attributes).forEach(attr => {
      if ((attr.name === 'src' || attr.name === 'href' || attr.name === 'xlink:href') && !allow.includes(attr.name)) {
        el.removeAttribute(attr.name);
      } else if (allow.includes(attr.name)) {
        const v = (el.getAttribute(attr.name) || '').trim().toLowerCase();
        if (v.startsWith('javascript:') || v.startsWith('data:text/html') || v.startsWith('vbscript:')) {
          el.removeAttribute(attr.name);
        }
      }
    });
  });
  return div.innerHTML;
}
