import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../src/rust/api/clipboard.dart' as api_clipboard;
import '../src/rust/api/history.dart' as api_history;
import '../src/rust/api/settings.dart' as api_settings;
import '../src/rust/api/stream.dart' as api_stream;
import '../src/rust/core/events.dart' show WindowActionKind;
import '../src/rust/core/settings_store.dart' show SettingsPatch;
import 'bridge/streams.dart';
import 'state/providers.dart';
import 'util/toast.dart';

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
  List<StreamSubscription> _clipboardSubs = const [];
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
        minimumSize: Size(320, 400),
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
    try {
      await windowManager.setPreventClose(true);
    } catch (e) {
      api_clipboard.feLog(message: 'setPreventClose failed: $e');
    }
    windowManager.addListener(this);

    // Tray setup is best-effort: a failure here (icon load, context menu,
    // platform channel) must not prevent the window/hotkey paths from
    // working — if the tray never comes up the user can still reach the
    // window via the global hotkey, and the cause is in the log.
    try {
      await _setupTray();
    } catch (e, stack) {
      api_clipboard.feLog(message: '_setupTray failed: $e\n$stack');
    }

    // Rust → Dart streams. Each group is best-effort so one broken sink
    // (e.g. helper-status on a platform without the helper) doesn't drop
    // the others.
    try {
      _windowActionSub = api_stream.streamWindowAction().listen((kind) {
        if (kind == WindowActionKind.showAndRaise) {
          performWindowDance();
        }
      });
    } catch (e, stack) {
      api_clipboard.feLog(message: 'streamWindowAction subscribe failed: $e\n$stack');
    }
    try {
      _helperStatusSub = api_stream.streamHelperStatus().listen((connected) {
        container.read(helperConnectedProvider.notifier).state = connected;
      });
    } catch (e, stack) {
      api_clipboard.feLog(message: 'streamHelperStatus subscribe failed: $e\n$stack');
    }

    // History-bearing streams → history provider.
    try {
      _clipboardSubs = subscribeClipboardStreams(container);
    } catch (e, stack) {
      api_clipboard.feLog(message: 'subscribeClipboardStreams failed: $e\n$stack');
    }
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

  /// Hide the window to the tray (no quit). Used after a copy when
  /// `closeToTray` is on.
  Future<void> hideWindow() async {
    await windowManager.hide();
  }

  /// Register/unregister a login auto-launch entry. Persistence of the
  /// `autoStart` flag itself is done by the settings screen via
  /// `updateSettings`; this applies the OS side-effect. Failures are logged
  /// only — the toggle still reads as saved.
  Future<void> applyAutoStart(bool enabled) async {
    try {
      final ok = enabled
          ? await launchAtStartup.enable()
          : await launchAtStartup.disable();
      if (!ok) {
        api_clipboard.feLog(message: 'launch_at_startup($enabled) returned false');
      }
    } catch (e) {
      api_clipboard.feLog(message: 'launch_at_startup($enabled) failed: $e');
    }
  }

  /// Quick-paste path (ported from `handleQuickPaste`): copy the item, float
  /// it to the top, hide the window, wait 200ms for the target app to regain
  /// focus, then simulate Ctrl+V. The window is hidden unconditionally
  /// (paste is meaningless with the history window in the way). The
  /// `simulatePasteCmd` Rust call is an M7 stub that returns `Err` until the
  /// platform paste injection lands — surface that as a toast rather than a
  /// silent no-op.
  Future<void> quickPaste(BigInt id) async {
    try {
      await api_clipboard.copyToClipboard(id: id);
    } catch (e) {
      showToast(container, '复制失败: $e');
      return;
    }
    try {
      await api_history.moveToTop(id: id);
    } catch (_) {
      // Non-fatal — the copy already succeeded.
    }
    await windowManager.hide();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    try {
      await api_clipboard.simulatePasteCmd();
    } catch (e) {
      showToast(container, '自动粘贴暂不可用: $e');
    }
  }

  Future<void> _setupTray() async {
    // tray_manager's Windows SetIcon uses LoadImage(IMAGE_ICON, LR_LOADFROMFILE),
    // which only reads .ico/.cur/.ani — a .png returns NULL and the icon is
    // silently invisible (setIcon still returns success). Linux (GTK) and
    // macOS (NSImage) load .png fine, so pick the asset by platform.
    final iconPath =
        Platform.isWindows ? 'assets/icon/icon.ico' : 'assets/icon/icon.png';
    await trayManager.setIcon(iconPath);
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

  @override
  void onTrayIconRightMouseDown() async {
    // Windows does not auto-show the context menu on a right-click — the
    // native tray_manager plugin only fires this event (WM_RBUTTONUP →
    // "onTrayIconRightMouseDown"). Pop the menu explicitly so the tray
    // right-click works on Windows. Linux (StatusNotifierItem) and macOS
    // (NSStatusItem.menu) already show the setContextMenu menu on their own,
    // and `popUpContextMenu` is not implemented on those platforms (calling
    // it would throw through the method channel) — so guard to Windows.
    // `bringAppToFront` runs the SetForegroundWindow trick so the menu
    // dismisses on click-away (TrackPopupMenu's classic quirk).
    if (Platform.isWindows) {
      // ignore: deprecated_member_use
      await trayManager.popUpContextMenu(bringAppToFront: true);
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
    for (final s in _clipboardSubs) {
      await s.cancel();
    }
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    await trayManager.destroy();
    await windowManager.destroy();
    exit(0);
  }
}