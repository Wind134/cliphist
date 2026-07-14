/** Matches Rust backend ClipboardItem struct */
export interface ClipboardItem {
  id: number;
  content: string;
  content_type: string;
  timestamp: string;
  preview: string;
  char_count: number;
  image_path: string | null;
  image_width: number | null;
  image_height: number | null;
  html_content: string | null;
}

/** Matches Rust backend Settings struct */
export interface Settings {
  close_to_tray: boolean;
  zoom_level: number;
  hotkey: string;
  auto_start: boolean;
  silent_start: boolean;
  double_tap_key: string;
  retention_days: number;
  window_width: number;
  window_height: number;
  window_user_resized: boolean;
}

export type ContentCategory = 'all' | 'image' | 'text' | 'link' | 'short' | 'rich';
