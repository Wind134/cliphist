import 'package:cliphist/src/rust/core/clipboard_engine.dart';
import 'package:cliphist/src/rust/core/settings_store.dart';
import 'package:cliphist/state/history_provider.dart';
import 'package:cliphist/state/providers.dart';
import 'package:cliphist/ui/history_view.dart';
import 'package:cliphist/ui/settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:cliphist/ui/theme.dart';

const testSettings = Settings(
  closeToTray: true,
  zoomLevel: 2,
  hotkey: 'Ctrl+Shift+V',
  autoStart: false,
  silentStart: false,
  doubleTapKey: 'Ctrl',
  retentionDays: 3,
  windowWidth: 320,
  windowHeight: 400,
  windowUserResized: true,
);

final testHistory = <ClipboardItem>[
  ClipboardItem(
    id: BigInt.one,
    content: '安全的富文本预览内容',
    contentType: 'rich',
    timestamp: '2026-08-17 14:00:00',
    preview: '安全的富文本预览内容',
    charCount: BigInt.from(10),
    htmlContent: '<p><strong>安全的富文本</strong><br>第二行内容</p>',
  ),
  ClipboardItem(
    id: BigInt.two,
    content: 'https://example.com',
    contentType: 'link',
    timestamp: '2026-08-17 13:59:00',
    preview: 'https://example.com',
    charCount: BigInt.from(19),
  ),
];

void main() {
  test('cliphist theme builds without error', () {
    expect(cliphistTheme(), isNotNull);
    expect(CliphistColors.bgBase, isNot(CliphistColors.surface));
    expect(CliphistColors.accent, isNot(CliphistColors.textPrimary));
  });

  testWidgets('history view fits the minimum window at 200% zoom', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith((ref) => testSettings),
          historyProvider.overrideWith((ref) => testHistory),
        ],
        child: MaterialApp(
          theme: cliphistTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(body: HistoryView()),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('ClipHist'), findsOneWidget);
  });

  testWidgets('settings cards stay usable at minimum width and 200% zoom', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith((ref) => testSettings)],
        child: MaterialApp(
          theme: cliphistTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(body: SettingsScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('ClipHist'), findsOneWidget);
  });
}
