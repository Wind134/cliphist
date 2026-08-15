// ClipHist Flutter migration spike — validates the three go/no-go criteria.
//
// A: FRB round-trip + StreamSink event stream (Rust core ↔ Dart UI).
// B: window_manager (OS-native window, show/hide/focus/alwaysOnTop) +
//    tray_manager (tray icon + context menu + menu-item callbacks reach FRB).
// C: evdev-helper independent binary — validated separately by `cargo build`.
//
// This is throwaway spike UI; the real UI is ported from `src/` in M4–M6.

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:menu_base/menu_base.dart';

import 'src/rust/frb_generated.dart';
import 'src/rust/api/spike.dart' as spike;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await RustLib.init();

  await windowManager.waitUntilReadyToShow(const WindowOptions(
    title: 'ClipHist (Flutter spike)',
    size: Size(420, 560),
    minimumSize: Size(320, 400),
    titleBarStyle: TitleBarStyle.normal, // OS-native decorations (spike B)
    center: true,
  ), () async {
    await windowManager.show();
    await windowManager.focus();
  });

  await _SpikeTray.instance.setup();

  runApp(const SpikeApp());
}

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClipHist spike',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F62A6)),
        useMaterial3: true,
      ),
      home: const SpikeHome(),
    );
  }
}

class SpikeHome extends StatefulWidget {
  const SpikeHome({super.key});
  @override
  State<SpikeHome> createState() => _SpikeHomeState();
}

class _SpikeHomeState extends State<SpikeHome> with WindowListener {
  String _history = '(not loaded)';
  String _copyResult = '(not called)';
  String _settingsResult = '(not called)';
  final List<String> _ticks = <String>[];
  bool _onTop = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // Spike A: subscribe to the 500ms event stream.
    spike.streamClipboardChanged().listen((event) {
      debugPrint('spike stream event: $event'); // runtime proof ticks arrive
      setState(() {
        _ticks.insert(0, event);
        if (_ticks.length > 8) _ticks.removeLast();
      });
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  // WindowListener — confirm show/hide/focus events fire (spike B).
  @override
  void onWindowFocus() => setState(() {});

  Future<void> _loadHistory() async {
    final items = spike.getHistory(); // sync round-trip
    setState(() => _history = items.join(', '));
  }

  Future<void> _copyOk() async {
    try {
      await spike.copyToClipboard(id: '42'); // async round-trip, success path
      setState(() => _copyResult = 'copy(42) -> Ok');
    } catch (e) {
      setState(() => _copyResult = 'copy(42) -> ERR $e');
    }
  }

  Future<void> _copyErr() async {
    try {
      await spike.copyToClipboard(id: ''); // async round-trip, error path
      setState(() => _copyResult = 'copy() -> Ok (unexpected!)');
    } catch (e) {
      setState(() => _copyResult = 'copy() -> ERR (expected) $e');
    }
  }

  Future<void> _updateSettings() async {
    final out = await spike.updateSettings(patch: 'zoom=1.2'); // async round-trip
    setState(() => _settingsResult = out);
  }

  Future<void> _toggleOnTop() async {
    _onTop = !_onTop;
    await windowManager.setAlwaysOnTop(_onTop); // spike B
    setState(() {});
  }

  Future<void> _doWindowDance() async {
    // Mini version of the "pop to top" window-action dance (spike B timing).
    await windowManager.setAlwaysOnTop(true);
    await windowManager.hide();
    await Future.delayed(const Duration(milliseconds: 30));
    await windowManager.show();
    await windowManager.focus();
    await Future.delayed(const Duration(milliseconds: 500));
    await windowManager.setAlwaysOnTop(false);
    setState(() => _onTop = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ClipHist · Flutter spike')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('A · FRB round-trip', [
            Text('history: $_history'),
            Wrap(spacing: 8, children: [
              FilledButton(onPressed: _loadHistory, child: const Text('getHistory()')),
              FilledButton(onPressed: _copyOk, child: const Text('copy(42)')),
              FilledButton(onPressed: _copyErr, child: const Text('copy(«»)')),
              FilledButton(onPressed: _updateSettings, child: const Text('updateSettings')),
            ]),
            Text('copy: $_copyResult'),
            Text('settings: $_settingsResult'),
          ]),
          _section('A · Stream (500ms ticks)', [
            const Text('latest events:'),
            for (final t in _ticks) Text('  $t'),
          ]),
          _section('B · window_manager', [
            Wrap(spacing: 8, children: [
              FilledButton(
                onPressed: () => windowManager.hide(),
                child: const Text('hide'),
              ),
              FilledButton(
                onPressed: () async {
                  await windowManager.show();
                  await windowManager.focus();
                },
                child: const Text('show+focus'),
              ),
              FilledButton(
                onPressed: _toggleOnTop,
                child: Text(_onTop ? 'alwaysOnTop: ON' : 'alwaysOnTop: off'),
              ),
              FilledButton(
                onPressed: _doWindowDance,
                child: const Text('window dance'),
              ),
            ]),
          ]),
          _section('B · tray_manager', [
            const Text('tray icon + 4-item menu active. '
                'Use the tray: 显示窗口 / 设置 / 清空历史 / 退出.'),
          ]),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

/// Owns the tray lifecycle for the spike. Menu-item callbacks reach into FRB
/// (spike B: tray -> FRB call path works).
class _SpikeTray with TrayListener {
  _SpikeTray._();
  static final _SpikeTray instance = _SpikeTray._();

  Future<void> setup() async {
    await trayManager.setIcon('assets/icon/icon.png');
    // tray_manager 0.5.3 on Linux has no setToolTip impl; setTitle is the
    // closest supported label and also exercises a second method channel call.
    await trayManager.setTitle('ClipHist');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(label: '显示窗口', onClick: (_) async {
        await windowManager.show();
        await windowManager.focus();
      }),
      MenuItem(label: '设置', onClick: (_) async {
        final r = await spike.updateSettings(patch: 'from-tray-settings');
        debugPrint('tray settings -> $r');
      }),
      MenuItem(label: '清空历史', onClick: (_) async {
        try {
          await spike.copyToClipboard(id: 'tray-clear');
          debugPrint('tray clear -> ok');
        } catch (e) {
          debugPrint('tray clear -> $e');
        }
      }),
      MenuItem.separator(),
      MenuItem(label: '退出', onClick: (_) => _quit()),
    ]));
    trayManager.addListener(this);
  }

  @override
  void onTrayIconMouseDown() async {
    // Left-click toggles window — same path the real hotkey/double-tap uses.
    final visible = await windowManager.isVisible();
    if (visible) {
      await windowManager.hide();
    } else {
      await windowManager.show();
      await windowManager.focus();
    }
  }

  void _quit() {
    trayManager.destroy();
    windowManager.destroy();
  }
}