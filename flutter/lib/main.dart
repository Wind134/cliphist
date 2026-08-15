import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'app_controller.dart';
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
///   4. Create the Riverpod container + start the [ClipHistController]
///      (window size restore, tray, stream subscriptions).
///   5. Run the app under an uncontrolled provider scope sharing the same
///      container so the controller can read/write providers.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await RustLib.init();
  await api_init.initAppState();

  // Configure the auto-launch helper with the running executable so the
  // settings "开机自动启动" toggle can register/unregister a login entry.
  // The path is the resolved exe; M10 packaging may override with a fixed
  // installed path.
  launchAtStartup.setup(
    appName: 'cliphist',
    appPath: Platform.executable,
  );

  final container = ProviderContainer();
  await ClipHistController.instance.start(container);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const ClipHistApp(),
    ),
  );
}