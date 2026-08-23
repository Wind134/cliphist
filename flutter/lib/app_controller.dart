import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager_platform_interface/hotkey_manager_platform_interface.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge/streams.dart';
import 'src/rust/api/clipboard.dart' as api_clipboard;
import 'src/rust/api/history.dart' as api_history;
import 'src/rust/api/settings.dart' as api_settings;
import 'src/rust/api/stream.dart' as api_stream;
import 'src/rust/core/settings_store.dart' show SettingsPatch;
import 'state/providers.dart';
import 'update/update_service.dart';
import 'util/hotkey_parser.dart';
import 'util/toast.dart';

/// Process-singleton owning the native window + tray lifecycle and the
/// Rust→Dart stream subscriptions. The window-action dance runs here because
/// the Rust core deliberately owns no native window handle.
///
/// The actual window-action *trigger* still originates in Rust (the hotkey and
/// double-tap paths call `request_window_action`); Dart consumes the coalesced
/// pending flag on its UI isolate. The Dart-side tray path calls
/// [performWindowDance] directly, and both converge on the same sequence.
class ClipHistController with WindowListener, TrayListener {
  ClipHistController._();
  static final ClipHistController instance = ClipHistController._();

  late final ProviderContainer container;

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _windowActionPoller;
  Timer? _resizeSaveTimer;
  HotKey? _registeredHotKey;
  bool _quitting = false;
  bool _windowDanceRunning = false;
  bool _windowDanceQueued = false;
  bool _windowActionPollErrorLogged = false;
  bool _quickPasteRunning = false;

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
        titleBarStyle: TitleBarStyle.normal, // OS-native window decorations
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

    if (!Platform.isLinux) {
      try {
        _subscriptions.add(
          HotKeyManagerPlatform.instance.onKeyEventReceiver.listen(
            _handleSystemHotKeyEvent,
          ),
        );
      } catch (e, stack) {
        api_clipboard.feLog(
          message: 'hotkey event subscription failed: $e\n$stack',
        );
      }
    }

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

    // Native wake events must be consumed on the Flutter UI isolate. The old
    // permanent FRB stream could silently stop delivering on Windows even
    // though the rdev hook logged successful double-taps. Polling one atomic
    // pending flag is deterministic, cheap, and coalesces bursty triggers.
    _windowActionPoller?.cancel();
    _windowActionPoller = Timer.periodic(
      const Duration(milliseconds: 80),
      _pollPendingWindowAction,
    );
    try {
      _subscriptions.add(
        api_stream.streamHelperStatus().listen((connected) {
          container.read(helperConnectedProvider.notifier).state = connected;
        }),
      );
    } catch (e, stack) {
      api_clipboard.feLog(
        message: 'streamHelperStatus subscribe failed: $e\n$stack',
      );
    }

    // History-bearing streams → history provider.
    try {
      _subscriptions.addAll(subscribeClipboardStreams(container));
    } catch (e, stack) {
      api_clipboard.feLog(
        message: 'subscribeClipboardStreams failed: $e\n$stack',
      );
    }

    // Never block startup on the network. A successful result is exposed as a
    // compact banner; failures stay quiet until the user checks manually.
    unawaited(checkForUpdates(silent: true));
  }

  /// Consume native wake requests on Flutter's UI isolate.
  void _pollPendingWindowAction(Timer _) {
    if (_quitting) return;
    try {
      if (api_stream.takePendingWindowAction()) {
        unawaited(performWindowDance(source: 'native trigger'));
      }
    } catch (e, stack) {
      if (_windowActionPollErrorLogged) return;
      _windowActionPollErrorLogged = true;
      api_clipboard.feLog(message: 'window action poll failed: $e\n$stack');
    }
  }

  /// Show and restore the window, briefly pulse always-on-top, then focus it.
  /// This raises a hidden Windows window without hiding it a second time first.
  Future<void> performWindowDance({String source = 'app'}) async {
    if (_quitting) return;
    if (_windowDanceRunning) {
      _windowDanceQueued = true;
      return;
    }

    _windowDanceRunning = true;
    try {
      do {
        _windowDanceQueued = false;
        api_clipboard.feLog(message: 'window dance: start ($source)');
        try {
          // Showing/restoring before the temporary top-most pulse is more
          // reliable on Windows than hiding an already-hidden window first.
          await windowManager.show();
          await windowManager.restore();
          await windowManager.setAlwaysOnTop(true);
          await windowManager.focus();
          final wakeGeneration = container.read(windowWakeGenerationProvider);
          container.read(windowWakeGenerationProvider.notifier).state =
              wakeGeneration + 1;
          await Future<void>.delayed(const Duration(milliseconds: 180));
          api_clipboard.feLog(message: 'window dance: completed ($source)');
        } catch (e, stack) {
          api_clipboard.feLog(
            message: 'window dance failed ($source): $e\n$stack',
          );
        } finally {
          try {
            await windowManager.setAlwaysOnTop(false);
          } catch (_) {}
        }
      } while (_windowDanceQueued && !_quitting);
    } finally {
      _windowDanceRunning = false;
    }
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
    // Linux builds are Wayland-only. The desktop environment owns the global
    // shortcut and invokes `cliphist --toggle-window`; no Keybinder/X11 plugin
    // is bundled or called.
    if (Platform.isLinux) {
      _registeredHotKey = null;
      api_clipboard.feLog(
        message: 'Wayland: use a system shortcut for --toggle-window',
      );
      return;
    }

    final previous = _registeredHotKey;
    final next = parseHotKey(shortcut);
    final manager = HotKeyManagerPlatform.instance;

    await manager.unregisterAll();
    _registeredHotKey = null;

    try {
      await manager.register(next);
      _registeredHotKey = next;
      api_clipboard.feLog(message: 'Registered native hotkey: $shortcut');
    } catch (_) {
      if (previous != null) {
        try {
          await manager.register(previous);
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

  void _handleSystemHotKeyEvent(Map<Object?, Object?> event) {
    if (event['type'] != 'onKeyDown') return;
    final data = event['data'];
    if (data is! Map) return;
    final identifier = data['identifier'];
    if (identifier != _registeredHotKey?.identifier) return;
    unawaited(performWindowDance(source: 'global hotkey'));
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

  /// Quick-paste path: copy the item, float it to the top, explicitly yield
  /// focus, hide the window, wait for the target app to regain focus, then
  /// simulate Ctrl+V. The window is hidden unconditionally
  /// (paste is meaningless with the history window in the way). The
  /// Native paste injection is best-effort; a missing Linux helper or denied
  /// accessibility permission is surfaced as a toast instead of a silent
  /// no-op.
  Future<void> quickPaste(BigInt id) async {
    if (_quickPasteRunning) {
      api_clipboard.feLog(message: 'quick paste: ignored duplicate id=$id');
      return;
    }
    _quickPasteRunning = true;
    api_clipboard.feLog(message: 'quick paste: start id=$id');
    try {
      try {
        await api_clipboard.copyToClipboard(id: id);
      } catch (e) {
        api_clipboard.feLog(message: 'quick paste: copy failed id=$id: $e');
        showToast(container, '复制失败: $e');
        return;
      }
      try {
        await api_history.moveToTop(id: id);
      } catch (e) {
        // Non-fatal — the copy already succeeded, but keep the reason visible.
        api_clipboard.feLog(message: 'quick paste: reorder failed id=$id: $e');
      }
      try {
        // Windows' Hide() only calls ShowWindow(SW_HIDE), which does not
        // deterministically activate the previously focused window. Blur()
        // explicitly activates the next visible native window first.
        if (Platform.isWindows || Platform.isMacOS) {
          await windowManager.blur();
        }
        await windowManager.hide();
      } catch (e) {
        api_clipboard.feLog(message: 'quick paste: hide failed id=$id: $e');
        showToast(container, '无法切回上一个窗口: $e');
        return;
      }
      api_clipboard.feLog(message: 'quick paste: window hidden id=$id');
      await _waitForPasteTargetFocus();
      try {
        await api_clipboard.simulatePasteCmd();
        api_clipboard.feLog(message: 'quick paste: completed id=$id');
      } catch (e) {
        api_clipboard.feLog(
          message: 'quick paste: injection failed id=$id: $e',
        );
        showToast(container, '自动粘贴暂不可用: $e');
      }
    } finally {
      _quickPasteRunning = false;
    }
  }

  Future<void> _waitForPasteTargetFocus() async {
    // isFocused is available on Windows/macOS. Polling avoids a fixed race,
    // while the final settling delay gives the newly activated application a
    // chance to finish its focus handlers before Ctrl/Cmd+V arrives.
    if (Platform.isWindows || Platform.isMacOS) {
      final deadline = DateTime.now().add(const Duration(milliseconds: 600));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        try {
          if (!await windowManager.isFocused()) break;
        } catch (_) {
          break;
        }
      }
      await Future<void>.delayed(
        Duration(milliseconds: Platform.isWindows ? 220 : 120),
      );
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  /// Persist game mode and keep both the settings screen and tray checkbox in
  /// sync. Rust applies the double-tap suppression atomically after the
  /// settings file has been saved successfully.
  Future<void> setGameMode(bool enabled) async {
    final updated = await api_settings.updateSettings(
      patch: SettingsPatch(gameMode: enabled),
    );
    container.read(settingsProvider.notifier).state = updated;
    try {
      await _setTrayContextMenu();
    } catch (e) {
      // The preference already succeeded; a cosmetic tray refresh must not
      // roll it back or make the setting appear to have failed.
      api_clipboard.feLog(message: 'game mode tray refresh failed: $e');
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
    await _setTrayContextMenu();
    trayManager.addListener(this);
    api_clipboard.feLog(message: '_setupTray done (icon+menu+listener)');
  }

  Future<void> _setTrayContextMenu() async {
    final gameMode = container.read(settingsProvider).gameMode;
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(
            label: '显示窗口',
            onClick: (_) {
              api_clipboard.feLog(message: 'tray menu: 显示窗口');
              unawaited(performWindowDance(source: 'tray show'));
            },
          ),
          MenuItem(
            label: '设置',
            onClick: (_) async {
              api_clipboard.feLog(message: 'tray menu: 设置');
              container.read(settingsOpenProvider.notifier).state = true;
              await performWindowDance(source: 'tray settings');
            },
          ),
          MenuItem.checkbox(
            key: 'game-mode',
            label: '游戏模式（暂停双击唤醒）',
            checked: gameMode,
            onClick: (_) async {
              final enabled = !container.read(settingsProvider).gameMode;
              api_clipboard.feLog(
                message: 'tray menu: game mode ${enabled ? "on" : "off"}',
              );
              try {
                await setGameMode(enabled);
              } catch (e) {
                api_clipboard.feLog(message: 'tray game mode failed: $e');
              }
            },
          ),
          MenuItem.separator(),
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
              await performWindowDance(source: 'tray update');
              await checkForUpdates();
            },
          ),
          MenuItem.separator(),
          MenuItem(
            label: '退出',
            onClick: (_) {
              api_clipboard.feLog(message: 'tray menu: 退出');
              quit();
            },
          ),
        ],
      ),
    );
  }

  // ── TrayListener ────────────────────────────────────────────────────────
  @override
  void onTrayIconMouseDown() {
    unawaited(_handleTrayIconMouseDown());
  }

  Future<void> _handleTrayIconMouseDown() async {
    final visible = await windowManager.isVisible();
    if (visible) {
      await windowManager.hide();
    } else {
      await performWindowDance(source: 'tray icon');
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(_handleTrayIconRightMouseDown());
  }

  Future<void> _handleTrayIconRightMouseDown() async {
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
  void onWindowClose() {
    unawaited(_handleWindowClose());
  }

  Future<void> _handleWindowClose() async {
    final closeToTray = container.read(settingsProvider).closeToTray;
    if (closeToTray) {
      await windowManager.hide();
    } else {
      quit();
    }
  }

  @override
  void onWindowResized() {
    // Trailing-edge debounce: persist the final settled size instead of an
    // arbitrary intermediate sample from a continuous drag.
    _resizeSaveTimer?.cancel();
    _resizeSaveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_persistWindowSize());
    });
  }

  Future<void> _persistWindowSize() async {
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

  /// Escape behavior: close settings first; otherwise hide when close-to-tray
  /// is enabled, or quit.
  Future<void> onEscape() async {
    if (container.read(settingsOpenProvider)) {
      container.read(settingsOpenProvider.notifier).state = false;
      return;
    }
    if (container.read(settingsProvider).closeToTray) {
      await windowManager.hide();
    } else {
      quit();
    }
  }

  void quit() {
    if (_quitting) return;
    _quitting = true;
    _resizeSaveTimer?.cancel();
    // Do not await cancellation of permanent FRB streams here. Their Rust
    // producers intentionally live for the process lifetime, so `cancel()` can
    // wait forever. The Windows log proved quit previously stopped on the very
    // first cancellation and never reached exit(0). A process exit is the
    // cleanup boundary; Windows reclaims the window, hooks, threads and tray
    // handle, while Explorer clears the icon on its next notification refresh.
    try {
      api_clipboard.feLog(message: 'quit: immediate exit(0)');
    } catch (_) {}
    exit(0);
  }
}
