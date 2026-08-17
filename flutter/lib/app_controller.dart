import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge/streams.dart';
import 'src/rust/api/clipboard.dart' as api_clipboard;
import 'src/rust/api/history.dart' as api_history;
import 'src/rust/api/settings.dart' as api_settings;
import 'src/rust/api/stream.dart' as api_stream;
import 'src/rust/core/events.dart' show WindowActionKind;
import 'src/rust/core/settings_store.dart' show SettingsPatch;
import 'state/providers.dart';
import 'update/update_service.dart';
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
  HotKey? _registeredHotKey;
  bool _quitting = false;

  Future<void> start(ProviderContainer c, {bool forceVisible = false}) async {
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
        titleBarStyle:
            TitleBarStyle.normal, // OS-native decorations (decision 3.6)
        skipTaskbar: false,
      ),
      () async {
        if (s.windowUserResized) {
          await windowManager.setSize(size);
        }
        // Silent start: create the window then immediately hide to tray so it
        // does not steal focus on login. The tray / hotkey reveals it later.
        // `forceVisible` (a cold `--toggle-window` launch) overrides this so
        // the window shows even if silentStart is on — the user pressed the
        // shortcut expecting to see it.
        if (s.silentStart && !forceVisible) {
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

    try {
      await applyHotkey(s.hotkey);
    } catch (e, stack) {
      api_clipboard.feLog(
        message: 'startup hotkey registration failed: $e\n$stack',
      );
    }

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
      api_clipboard.feLog(
        message: 'streamWindowAction subscribe failed: $e\n$stack',
      );
    }
    try {
      _helperStatusSub = api_stream.streamHelperStatus().listen((connected) {
        container.read(helperConnectedProvider.notifier).state = connected;
      });
    } catch (e, stack) {
      api_clipboard.feLog(
        message: 'streamHelperStatus subscribe failed: $e\n$stack',
      );
    }

    // History-bearing streams → history provider.
    try {
      _clipboardSubs = subscribeClipboardStreams(container);
    } catch (e, stack) {
      api_clipboard.feLog(
        message: 'subscribeClipboardStreams failed: $e\n$stack',
      );
    }

    // Never block startup on the network. A successful result is exposed as a
    // compact banner; failures stay quiet until the user checks manually.
    unawaited(checkForUpdates(silent: true));
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
        throw StateError('系统拒绝了开机启动设置');
      }
    } catch (e, stack) {
      api_clipboard.feLog(message: 'launch_at_startup($enabled) failed: $e');
      api_clipboard.feLog(message: '$stack');
      rethrow;
    }
  }

  /// Register a system-wide hotkey through a native Flutter plugin. Keeping
  /// this out of FRB is important: macOS requires registration on its main
  /// event loop, while Windows hotkey handles are thread-affine.
  Future<void> applyHotkey(String shortcut) async {
    final previous = _registeredHotKey;
    final next = _parseHotKey(shortcut);

    await hotKeyManager.unregisterAll();
    _registeredHotKey = null;

    // The plugin uses X11 keybinder on Linux. Wayland users bind
    // `cliphist --toggle-window` in their desktop shortcut settings instead.
    final wayland =
        Platform.isLinux &&
        Platform.environment['XDG_SESSION_TYPE']?.toLowerCase() == 'wayland';
    if (wayland) {
      api_clipboard.feLog(
        message: 'Wayland: skipped app global hotkey; use --toggle-window',
      );
      return;
    }

    try {
      await hotKeyManager.register(
        next,
        keyDownHandler: (_) => unawaited(performWindowDance()),
      );
      _registeredHotKey = next;
      api_clipboard.feLog(message: 'Registered native hotkey: $shortcut');
    } catch (_) {
      if (previous != null) {
        try {
          await hotKeyManager.register(
            previous,
            keyDownHandler: (_) => unawaited(performWindowDance()),
          );
          _registeredHotKey = previous;
        } catch (rollbackError) {
          api_clipboard.feLog(
            message: 'hotkey rollback failed: $rollbackError',
          );
        }
      }
      rethrow;
    }
  }

  HotKey _parseHotKey(String shortcut) {
    final parts = shortcut
        .split('+')
        .map((part) => part.trim().toUpperCase())
        .where((part) => part.isNotEmpty)
        .toList();
    final modifiers = <HotKeyModifier>[];
    PhysicalKeyboardKey? key;
    for (final part in parts) {
      switch (part) {
        case 'COMMANDORCONTROL':
        case 'CMDORCTRL':
        case 'CTRL':
        case 'CONTROL':
          modifiers.add(HotKeyModifier.control);
        case 'COMMAND':
        case 'CMD':
        case 'SUPER':
        case 'META':
        case 'WIN':
          modifiers.add(HotKeyModifier.meta);
        case 'SHIFT':
          modifiers.add(HotKeyModifier.shift);
        case 'ALT':
        case 'OPTION':
          modifiers.add(HotKeyModifier.alt);
        default:
          key = _physicalKey(part);
      }
    }
    if (key == null || modifiers.isEmpty) {
      throw FormatException('无效的快捷键: $shortcut');
    }
    return HotKey(
      key: key,
      modifiers: modifiers.toSet().toList(),
      scope: HotKeyScope.system,
    );
  }

  PhysicalKeyboardKey? _physicalKey(String value) {
    if (value.length == 1) {
      const letters = <String, PhysicalKeyboardKey>{
        'A': PhysicalKeyboardKey.keyA,
        'B': PhysicalKeyboardKey.keyB,
        'C': PhysicalKeyboardKey.keyC,
        'D': PhysicalKeyboardKey.keyD,
        'E': PhysicalKeyboardKey.keyE,
        'F': PhysicalKeyboardKey.keyF,
        'G': PhysicalKeyboardKey.keyG,
        'H': PhysicalKeyboardKey.keyH,
        'I': PhysicalKeyboardKey.keyI,
        'J': PhysicalKeyboardKey.keyJ,
        'K': PhysicalKeyboardKey.keyK,
        'L': PhysicalKeyboardKey.keyL,
        'M': PhysicalKeyboardKey.keyM,
        'N': PhysicalKeyboardKey.keyN,
        'O': PhysicalKeyboardKey.keyO,
        'P': PhysicalKeyboardKey.keyP,
        'Q': PhysicalKeyboardKey.keyQ,
        'R': PhysicalKeyboardKey.keyR,
        'S': PhysicalKeyboardKey.keyS,
        'T': PhysicalKeyboardKey.keyT,
        'U': PhysicalKeyboardKey.keyU,
        'V': PhysicalKeyboardKey.keyV,
        'W': PhysicalKeyboardKey.keyW,
        'X': PhysicalKeyboardKey.keyX,
        'Y': PhysicalKeyboardKey.keyY,
        'Z': PhysicalKeyboardKey.keyZ,
        '0': PhysicalKeyboardKey.digit0,
        '1': PhysicalKeyboardKey.digit1,
        '2': PhysicalKeyboardKey.digit2,
        '3': PhysicalKeyboardKey.digit3,
        '4': PhysicalKeyboardKey.digit4,
        '5': PhysicalKeyboardKey.digit5,
        '6': PhysicalKeyboardKey.digit6,
        '7': PhysicalKeyboardKey.digit7,
        '8': PhysicalKeyboardKey.digit8,
        '9': PhysicalKeyboardKey.digit9,
      };
      return letters[value];
    }
    const named = <String, PhysicalKeyboardKey>{
      'SPACE': PhysicalKeyboardKey.space,
      'ENTER': PhysicalKeyboardKey.enter,
      'RETURN': PhysicalKeyboardKey.enter,
      'TAB': PhysicalKeyboardKey.tab,
      'ESC': PhysicalKeyboardKey.escape,
      'ESCAPE': PhysicalKeyboardKey.escape,
      'BACKSPACE': PhysicalKeyboardKey.backspace,
      'F1': PhysicalKeyboardKey.f1,
      'F2': PhysicalKeyboardKey.f2,
      'F3': PhysicalKeyboardKey.f3,
      'F4': PhysicalKeyboardKey.f4,
      'F5': PhysicalKeyboardKey.f5,
      'F6': PhysicalKeyboardKey.f6,
      'F7': PhysicalKeyboardKey.f7,
      'F8': PhysicalKeyboardKey.f8,
      'F9': PhysicalKeyboardKey.f9,
      'F10': PhysicalKeyboardKey.f10,
      'F11': PhysicalKeyboardKey.f11,
      'F12': PhysicalKeyboardKey.f12,
    };
    return named[value];
  }

  Future<void> checkForUpdates({bool silent = false}) async {
    final previous = container.read(updateStateProvider);
    container.read(updateStateProvider.notifier).state = AppUpdateState(
      phase: UpdatePhase.checking,
      currentVersion: previous.currentVersion,
      latestVersion: previous.latestVersion,
      releaseUrl: previous.releaseUrl,
    );
    final result = await UpdateService().check(
      currentVersion: previous.currentVersion.isEmpty
          ? null
          : previous.currentVersion,
    );
    container.read(updateStateProvider.notifier).state = result;
    if (silent) return;
    switch (result.phase) {
      case UpdatePhase.available:
        showToast(container, '发现新版本 v${result.latestVersion}');
      case UpdatePhase.upToDate:
        showToast(container, '当前已是最新版本');
      case UpdatePhase.failed:
        showToast(container, '检查更新失败: ${result.errorMessage}');
      case UpdatePhase.idle:
      case UpdatePhase.checking:
        break;
    }
  }

  Future<void> openLatestRelease() async {
    final uri = container.read(updateStateProvider).releaseUrl;
    if (uri == null) return;
    try {
      await UpdateService.openRelease(uri);
    } catch (e) {
      showToast(container, '打开下载页失败: $e');
    }
  }

  /// Quick-paste path (ported from `handleQuickPaste`): copy the item, float
  /// it to the top, hide the window, wait 200ms for the target app to regain
  /// focus, then simulate Ctrl+V. The window is hidden unconditionally
  /// (paste is meaningless with the history window in the way). The
  /// Native paste injection is best-effort; a missing Linux helper or denied
  /// accessibility permission is surfaced as a toast instead of a silent
  /// no-op.
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
    final iconPath = Platform.isWindows
        ? 'assets/icon/icon.ico'
        : 'assets/icon/icon.png';
    await trayManager.setIcon(iconPath);
    // Hover label is cosmetic and platform support is asymmetric: tray_manager
    // implements setTitle on Linux but NOT on Windows (NotImplemented → throws
    // MissingPluginException), and setToolTip the other way around on some
    // platforms. Try each best-effort so a missing impl can't abort the
    // context-menu + listener registration below — that abort was why BOTH tray
    // clicks were dead on Windows (setIcon succeeded → icon visible, but
    // setTitle threw → setContextMenu + addListener never ran → no menu, no
    // click handlers).
    try {
      await trayManager.setTitle('ClipHist');
    } catch (_) {
      // setTitle not implemented on this platform (Windows) — ignore.
    }
    try {
      await trayManager.setToolTip('ClipHist');
    } catch (_) {
      // setToolTip not implemented on this platform — ignore.
    }
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(
            label: '显示窗口',
            onClick: (_) {
              api_clipboard.feLog(message: 'tray menu: 显示窗口');
              unawaited(performWindowDance());
            },
          ),
          MenuItem(
            label: '设置',
            onClick: (_) async {
              api_clipboard.feLog(message: 'tray menu: 设置');
              container.read(settingsOpenProvider.notifier).state = true;
              await performWindowDance();
            },
          ),
          MenuItem(
            label: '清空历史',
            onClick: (_) async {
              api_clipboard.feLog(message: 'tray menu: 清空历史');
              try {
                await api_history
                    .clearHistory(); // emits history-replace(empty)
              } catch (e) {
                api_clipboard.feLog(message: 'tray clear failed: $e');
              }
            },
          ),
          MenuItem(
            label: '检查更新',
            onClick: (_) async {
              container.read(settingsOpenProvider.notifier).state = true;
              await performWindowDance();
              await checkForUpdates();
            },
          ),
          MenuItem.separator(),
          MenuItem(
            label: '退出',
            onClick: (_) {
              api_clipboard.feLog(message: 'tray menu: 退出');
              unawaited(quit());
            },
          ),
        ],
      ),
    );
    trayManager.addListener(this);
    api_clipboard.feLog(message: '_setupTray done (icon+menu+listener)');
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
    if (_quitting) return;
    _quitting = true;
    api_clipboard.feLog(message: 'quit() invoked');
    // Best-effort cleanup — every step is guarded so a failure can never
    // prevent the hard `exit(0)` below. The OS reclaims all resources (window,
    // sockets, threads) on process exit regardless; we only bother destroying
    // the tray icon explicitly so it does not linger in the Windows
    // notification area after the process is gone (a classic Windows tray
    // quirk). Crucially, `windowManager.destroy()` can be intercepted by our
    // own `onWindowClose` (when close-to-tray is on), and stream cancels can
    // throw — without the try/catch the unawaited Future's error would be
    // swallowed by the zone and `exit(0)` would never run, which is exactly
    // why the tray "退出" item appeared to do nothing.
    try {
      await _windowActionSub?.cancel();
    } catch (e) {
      api_clipboard.feLog(message: 'quit: windowActionSub cancel failed: $e');
    }
    try {
      await _helperStatusSub?.cancel();
    } catch (e) {
      api_clipboard.feLog(message: 'quit: helperStatusSub cancel failed: $e');
    }
    for (final s in _clipboardSubs) {
      try {
        await s.cancel();
      } catch (e) {
        api_clipboard.feLog(message: 'quit: clipboardSub cancel failed: $e');
      }
    }
    try {
      trayManager.removeListener(this);
    } catch (_) {}
    try {
      windowManager.removeListener(this);
    } catch (_) {}
    try {
      await trayManager.destroy();
    } catch (e) {
      api_clipboard.feLog(message: 'quit: tray destroy failed: $e');
    }
    try {
      await hotKeyManager.unregisterAll();
    } catch (e) {
      api_clipboard.feLog(message: 'quit: hotkey unregister failed: $e');
    }
    // Skip windowManager.destroy() — it can route through onWindowClose
    // (close-to-tray) and hide instead of destroying, which delays/loses the
    // exit. The OS tears the window down on exit(0) anyway.
    api_clipboard.feLog(message: 'quit: calling exit(0)');
    exit(0);
  }
}
