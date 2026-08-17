import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'app_controller.dart';
import 'src/rust/api/clipboard.dart' as api_clipboard;
import 'src/rust/api/init.dart' as api_init;
import 'src/rust/frb_generated.dart';

/// ClipHist entry point.
///
/// Boot order (mirrors the old Tauri `run()` setup):
///   1. Flutter binding + window_manager init.
///   2. FRB `RustLib.init()` (loads the Rust cdylib).
///   3. `initAppState()` — load history/settings, install panic hook, spawn
///      the four background tasks (clipboard poll / window-action worker /
///      helper-status monitor / clean-expired).
///   4. Wire a Dart-side error sink: `FlutterError.onError` +
///      `runZonedGuarded` route uncaught Flutter/async errors to the Rust log
///      (`cliphist.log`) via `feLog`. Release builds show no red error screen,
///      so without this a startup or widget-build failure is a blank window
///      with no clue why.
///   5. Schedule `runApp` *before* the controller's `start()` so the Flutter
///      UI renders into the (not-yet-shown) native window first. Previously
///      `start()` awaited `windowManager.show()` before `runApp` ran, so the
///      window appeared with no first frame painted yet — a blank flash.
///   6. `start()` (window size restore, show/hide, tray, stream
///      subscriptions), wrapped so a single native-init failure neither
///      blanks the app nor hides the cause: it is logged and skipped, the UI
///      keeps running.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await RustLib.init();

  // Single-instance guard: if ClipHist is already running, this second
  // process pokes the existing instance to bring its window forward and
  // exits. This also covers the Wayland `--toggle-window` CLI (a system
  // shortcut bound to `cliphist --toggle-window` just pokes the running
  // instance). Must run before init_app_state so we never start a second
  // clipboard poll loop / second tray icon. `forceVisible` is true when
  // --toggle-window launched us from cold (no other instance), so the window
  // shows instead of starting hidden by silentStart.
  final instance = await api_init.checkSingleInstance();
  if (!instance.firstInstance) {
    exit(0);
  }

  await api_init.initAppState();

  // Configure the auto-launch helper with the running executable so the
  // settings "开机自动启动" toggle can register/unregister a login entry.
  // The path is the resolved exe; M10 packaging may override with a fixed
  // installed path.
  launchAtStartup.setup(appName: 'cliphist', appPath: Platform.executable);

  // Route Flutter framework errors (widget build throws, rendering errors)
  // to the Rust log so a release-mode blank window is diagnosable. The Rust
  // panic hook covers Rust-side panics; this is the Dart-side counterpart.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    api_clipboard.feLog(
      message:
          'FlutterError: ${details.exceptionAsString()}\n'
          '${details.stack}',
    );
  };

  final container = ProviderContainer();

  // Run the app inside a guarded zone so uncaught async errors (outside the
  // Flutter widget tree) also land in the log rather than vanishing in
  // release. runApp schedules the first frame and returns immediately; the
  // UI begins rendering into the (still-hidden) native window right away.
  runZonedGuarded(
    () {
      runApp(
        UncontrolledProviderScope(
          container: container,
          child: const ClipHistApp(),
        ),
      );
    },
    (error, stack) {
      api_clipboard.feLog(message: 'Uncaught zone error: $error\n$stack');
    },
  );

  // Start the controller after runApp is scheduled so the first frame has a
  // head start before the window is shown. A failure here is logged, not
  // fatal — the Flutter app keeps running and the user can still read the
  // log to see what broke.
  try {
    await ClipHistController.instance.start(
      container,
      forceVisible: instance.forceVisible,
    );
  } catch (e, stack) {
    api_clipboard.feLog(
      message: 'ClipHistController.start() failed: $e\n$stack',
    );
  }
}
