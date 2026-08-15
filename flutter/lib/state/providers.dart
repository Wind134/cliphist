import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/settings.dart' as api_settings;
import '../src/rust/core/settings_store.dart' show Settings;

/// In-memory settings (single source of truth, mirrors the Rust `AppState`
/// settings). Seeded synchronously from `getSettings()`; the controller and
/// settings screen write back through `updateSettings` and refresh this.
final settingsProvider = StateProvider<Settings>(
  (ref) => api_settings.getSettings(),
);

/// Whether the settings panel is open (toggled by tray "设置" and the
/// Escape/Esc key). The history list is shown when false.
final settingsOpenProvider = StateProvider<bool>((ref) => false);

/// Whether the privileged evdev double-tap helper is connected (Linux). Driven
/// by `streamHelperStatus`; shown in the settings panel (M5) as the
/// "authorized / needs authorization" indicator.
final helperConnectedProvider = StateProvider<bool>((ref) => false);

/// Ephemeral toast message (M4 wires the toast widget). Held as state so any
/// part of the UI can surface feedback.
final toastMessageProvider = StateProvider<String>((ref) => '');