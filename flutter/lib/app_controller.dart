import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:menu_base/menu_base.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../src/rust/api/clipboard.dart' as api_clipboard;
import '../src/rust/api/history.dart' as api_history;
import '../src/rust/api/settings.dart' as api_settings;
import '../src/rust/api/stream.dart' as api_stream;
import '../src/rust/core/events.dart' show WindowActionKind;
import '../src/rust/core/settings_store.dart' show SettingsPatch;
import 'state/providers.dart';

/// Process-singleton owning the native window + tray lifecycle and the
/// Rust→Dart stream subscriptions. Replaces the old Tauri `tray.rs` + the
/// window-action worker's native half (the dance runs here in Dart, per
/// decision 3.2 — the Rust core owns no window handle).
///
/// The actual window-action *trigger* still originates in Rust (M7 hotkey /
/// M8 double-tap call `request_window_action`, which emits a
/// `WindowActionKind.showAndRaise` event); the Dart-side tray path calls
/// [performWindowDance] directly. Both converge on the same sequence.
class ClipHistController with WindowListener, TrayListener {
  ClipHistController._();
  static final ClipHistController instance = ClipHistController._();

  late final ProviderContainer container;

  StreamSubscription<WindowActionKind>? _windowActionSub;
  StreamSubscription<bool>? _helperStatusSub;
  int _lastResizeSave = 0;

  Future<void> start(ProviderContainer c) async {
    container = c;

    final s = api_settings.getSettings();
    container.read(settingsProvider.notifier).state = s;

    final size = s.windowUserResized
        ? Size(s.windowWidth.toDouble(), s.windowHeight.toDouble())
        : const Size(400, 600);

    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'ClipHist',
        minimumSize: const Size(320, 400),
        titleBarStyle: TitleBarStyle.normal, // OS-native decorations (decision 3.6)
        skipTaskbar: false,
      ),
      () async {
        if (s.windowUserResized) {
          await windowManager.setSize(size);
        }
        // Silent start: create the window then immediately hide to tray so it
        // does not steal focus on login. The tray / hotkey reveals it later.
        if (s.silentStart) {
          await windowManager.show();
          await windowManager.hide();
        } else {
          await windowManager.show();
          await windowManager.focus();
        }
      },
    );

    // Intercept the native close button so it respects "close to tray".
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    await _setupTray();

    // Rust → Dart streams.
    _windowActionSub = api_stream.streamWindowAction().listen((kind) {
      if (kind == WindowActionKind.showAndRaise) {
        performWindowDance();
      }
    });
    _helperStatusSub = api_stream.streamHelperStatus().listen((connected) {
      container.read(helperConnectedProvider.notifier).state = connected;
    });
  }

  /// The "pop to top" window-action dance, ported from the old Tauri worker:
  /// pin on top, hide, show + focus, then release always-on-top. Bounces
  /// always_on_top + hide/show because some compositors ignore a bare
  /// set_focus and leave the window below.
  Future<void> performWindowDance() async {
    await windowManager.setAlwaysOnTop(true);
    await windowManager.hide();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await windowManager.show();
    await windowManager.focus();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await windowManager.setAlwaysOnTop(false);
  }

  Future<void> _setupTray() async {
    await trayManager.setIcon('assets/icon/icon.png');
    // tray_manager 0.5.3 on Linux has no setToolTip impl (spike B); setTitle
    // is the closest supported label.
    await trayManager.setTitle('ClipHist');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(
        label: '显示窗口',
        onClick: (_) => performWindowDance(),
      ),
      MenuItem(
        label: '设置',
        onClick: (_) async {
          container.read(settingsOpenProvider.notifier).state = true;
          await performWindowDance();
        },
      ),
      MenuItem(
        label: '清空历史',
        onClick: (_) async {
          try {
            await api_history.clearHistory(); // emits history-replace(empty)
          } catch (e) {
            api_clipboard.feLog(message: 'tray clear failed: $e');
          }
        },
      ),
      MenuItem.separator(),
      MenuItem(label: '退出', onClick: (_) => quit()),
    ]));
    trayManager.addListener(this);
  }

  // ── TrayListener ────────────────────────────────────────────────────────
  @override
  void onTrayIconMouseDown() async {
    final visible = await windowManager.isVisible();
    if (visible) {
      await windowManager.hide();
    } else {
      await performWindowDance();
    }
  }

  // ── WindowListener ──────────────────────────────────────────────────────
  @override
  void onWindowClose() async {
    final closeToTray = container.read(settingsProvider).closeToTray;
    if (closeToTray) {
      await windowManager.hide();
    } else {
      await quit();
    }
  }

  @override
  void onWindowResized() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    // Throttle to 500ms — mirrors the old Tauri resize handler.
    if (now - _lastResizeSave < 500) return;
    _lastResizeSave = now;
    final size = await windowManager.getSize();
    try {
      final updated = await api_settings.updateSettings(
        patch: SettingsPatch(
          windowWidth: size.width.round(),
          windowHeight: size.height.round(),
          windowUserResized: true,
        ),
      );
      container.read(settingsProvider.notifier).state = updated;
    } catch (e) {
      api_clipboard.feLog(message: 'resize persist failed: $e');
    }
  }

  /// Escape behavior (ported from app.svelte `handleKeydown`): if settings is
  /// open, close it; else hide (close-to-tray) or quit.
  Future<void> onEscape() async {
    if (container.read(settingsOpenProvider)) {
      container.read(settingsOpenProvider.notifier).state = false;
      return;
    }
    if (container.read(settingsProvider).closeToTray) {
      await windowManager.hide();
    } else {
      await quit();
    }
  }

  Future<void> quit() async {
    await _windowActionSub?.cancel();
    await _helperStatusSub?.cancel();
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    await trayManager.destroy();
    await windowManager.destroy();
    exit(0);
  }
}