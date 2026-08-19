import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/settings.dart' as api_settings;
import '../src/rust/core/settings_store.dart' show Settings;
import '../update/update_service.dart';

/// In-memory settings (single source of truth, mirrors the Rust `AppState`
/// settings). Seeded synchronously from `getSettings()`; the controller and
/// settings screen write back through `updateSettings` and refresh this.
final settingsProvider = StateProvider<Settings>(
  (ref) => api_settings.getSettings(),
);

/// Whether the settings panel is open (toggled by tray "设置" and the
/// Escape/Esc key). The history list is shown when false.
final settingsOpenProvider = StateProvider<bool>((ref) => false);

/// Monotonically increases after the main window has been raised and focused.
/// The history view listens to this signal so a previously-focused search box
/// cannot swallow the 1–9 quick-paste keys after a tray/hotkey wake.
final windowWakeGenerationProvider = StateProvider<int>((ref) => 0);

/// Whether the privileged evdev double-tap helper is connected on Linux.
/// Windows and macOS use their native listener and report readiness separately.
final helperConnectedProvider = StateProvider<bool>((ref) => false);

/// Ephemeral toast message. Held as state so any part of the UI can surface
/// feedback.
final toastMessageProvider = StateProvider<String>((ref) => '');

/// Result of the latest GitHub Releases update check. The controller performs
/// a silent check after startup; settings can trigger a manual retry.
final updateStateProvider = StateProvider<AppUpdateState>(
  (ref) => const AppUpdateState.idle(),
);
