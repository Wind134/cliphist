import 'dart:convert';

import 'package:cliphist/app.dart';
import 'package:cliphist/src/rust/core/clipboard_engine.dart';
import 'package:cliphist/src/rust/core/settings_store.dart';
import 'package:cliphist/state/history_provider.dart';
import 'package:cliphist/state/providers.dart';
import 'package:cliphist/ui/history_view.dart';
import 'package:cliphist/ui/settings_screen.dart';
import 'package:cliphist/ui/theme.dart';
import 'package:cliphist/util/image_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const testSettings = Settings(
  closeToTray: true,
  zoomLevel: 2,
  hotkey: 'Ctrl+Shift+V',
  autoStart: false,
  silentStart: false,
  doubleTapKey: 'Ctrl',
  gameMode: false,
  retentionDays: 3,
  windowWidth: 320,
  windowHeight: 400,
  windowUserResized: true,
  windowX: 0,
  windowY: 0,
  windowPositioned: false,
  windowAdaptive: false,
  acrylicEnabled: false,
  themeMode: 'light',
  listDensity: 'standard',
);

const layoutSettings = Settings(
  closeToTray: true,
  zoomLevel: 1,
  hotkey: 'Ctrl+Shift+V',
  autoStart: false,
  silentStart: true,
  doubleTapKey: 'Ctrl',
  gameMode: false,
  retentionDays: 3,
  windowWidth: 400,
  windowHeight: 600,
  windowUserResized: true,
  windowX: 120,
  windowY: 80,
  windowPositioned: true,
  windowAdaptive: true,
  acrylicEnabled: false,
  themeMode: 'light',
  listDensity: 'standard',
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

final longHistory = <ClipboardItem>[
  ClipboardItem(
    id: BigInt.from(42),
    content: List.filled(40, '完整的多行剪贴板内容').join('\n'),
    contentType: 'text',
    timestamp: '2026-08-23 16:00:00',
    preview: '完整的多行剪贴板内容…',
    charCount: BigInt.from(400),
  ),
];

void main() {
  test('cliphist theme builds without error', () {
    expect(cliphistTheme(), isNotNull);
    expect(CliphistColors.bgBase, isNot(CliphistColors.surface));
    expect(CliphistColors.accent, isNot(CliphistColors.textPrimary));
  });

  test('quick-paste keys include the number row and numeric keypad', () {
    expect(quickPasteIndexForKey(LogicalKeyboardKey.digit1), 1);
    expect(quickPasteIndexForKey(LogicalKeyboardKey.digit9), 9);
    expect(quickPasteIndexForKey(LogicalKeyboardKey.numpad1), 1);
    expect(quickPasteIndexForKey(LogicalKeyboardKey.numpad9), 9);
    expect(quickPasteIndexForKey(LogicalKeyboardKey.digit0), isNull);
  });

  testWidgets('search field keeps backspace while focused', (tester) async {
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith((ref) => testSettings),
        historyProvider.overrideWith((ref) => testHistory),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: cliphistTheme(),
          home: const Scaffold(body: HistoryView()),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    expect(container.read(searchQueryProvider), 'abc');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(container.read(searchQueryProvider), 'ab');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'ab',
    );
  });

  testWidgets('window wake returns focus to numeric quick-paste', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith((ref) => testSettings),
        historyProvider.overrideWith((ref) => testHistory),
      ],
    );
    addTearDown(container.dispose);
    BigInt? pastedId;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: cliphistTheme(),
          home: Scaffold(
            body: HistoryView(onQuickPaste: (id) => pastedId = id),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
    );

    container.read(windowWakeGenerationProvider.notifier).state++;
    await tester.pump();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.digit2);
    await tester.pump(const Duration(milliseconds: 130));

    expect(pastedId, BigInt.two);
  });

  testWidgets('row selection restores numeric quick-paste focus and bounces', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith((ref) => testSettings),
        historyProvider.overrideWith((ref) => testHistory),
      ],
    );
    addTearDown(container.dispose);
    BigInt? pastedId;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: cliphistTheme(),
          home: Scaffold(
            body: HistoryView(onQuickPaste: (id) => pastedId = id),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('history-item-tap-1')));
    await tester.pump();
    expect(container.read(selectedIndexProvider), 0);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.digit2);
    await tester.pump(const Duration(milliseconds: 130));
    expect(pastedId, BigInt.two);
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
    expect(find.text('剪贴板历史'), findsOneWidget);
  });

  testWidgets('truncated rows open the complete content in the preview', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith((ref) => testSettings),
          historyProvider.overrideWith((ref) => longHistory),
        ],
        child: MaterialApp(
          theme: cliphistTheme(),
          home: const Scaffold(body: HistoryView()),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('history-item-tap-42')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('history-item-details-42')));
    // Row taps wait out the double-tap (copy) window before firing.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('preview-overlay')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('history-item-full-content-42')),
      findsOneWidget,
    );
    expect(find.byType(SelectionArea), findsWidgets);
  });

  testWidgets('space toggles the preview and blocks list shortcuts', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith((ref) => testSettings),
        historyProvider.overrideWith((ref) => testHistory),
      ],
    );
    addTearDown(container.dispose);
    BigInt? pastedId;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: cliphistTheme(),
          home: Scaffold(
            body: HistoryView(onQuickPaste: (id) => pastedId = id),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('history-item-tap-1')));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('preview-overlay')), findsOneWidget);
    expect(find.text('富文本'), findsWidgets);

    // Quick-paste and delete must not act behind the overlay.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump(const Duration(milliseconds: 130));
    expect(pastedId, isNull);

    // → moves to the next item and keeps the list selection in sync.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(container.read(selectedIndexProvider), 1);
    expect(find.text('在浏览器打开'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(container.read(selectedIndexProvider), 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('preview-overlay')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('preview-overlay')), findsNothing);

    // Quick-paste works again once the overlay is gone.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump(const Duration(milliseconds: 130));
    expect(pastedId, BigInt.two);
  });

  testWidgets('space in the search field types instead of previewing', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith((ref) => testSettings),
        historyProvider.overrideWith((ref) => testHistory),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: cliphistTheme(),
          home: const Scaffold(body: HistoryView()),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('history-item-tap-1')));
    await tester.pump();
    expect(container.read(selectedIndexProvider), 0);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('preview-overlay')), findsNothing);
  });

  testWidgets('text preview toggles wrap and closes from the backdrop', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith((ref) => testSettings),
          historyProvider.overrideWith((ref) => longHistory),
        ],
        child: MaterialApp(
          theme: cliphistTheme(),
          home: const Scaffold(body: HistoryView()),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('history-item-tap-42')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('history-item-preview-42')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('400 字 · 40 行'), findsOneWidget);
    expect(find.text('40'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('preview-seg-自动换行')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tapAt(const Offset(5, 590));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('preview-overlay')), findsNothing);
  });

  testWidgets('image rows use the content block and open the preview', (
    tester,
  ) async {
    seedImageCache(
      BigInt.from(7),
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPj/HwADAgH/'
        'p+Fm6gAAAABJRU5ErkJggg==',
      ),
    );
    addTearDown(clearImageCache);
    final images = <ClipboardItem>[
      ClipboardItem(
        id: BigInt.from(7),
        content: '',
        contentType: 'image',
        timestamp: '2026-08-23 16:00:00',
        preview: '图片 865x1472',
        charCount: BigInt.zero,
        imageWidth: 865,
        imageHeight: 1472,
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith((ref) => testSettings),
          historyProvider.overrideWith((ref) => images),
        ],
        child: MaterialApp(
          theme: cliphistTheme(),
          home: const Scaffold(body: HistoryView()),
        ),
      ),
    );
    expect(find.text('865 × 1472 px'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('history-item-thumb-7')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('preview-overlay')), findsOneWidget);
    expect(find.text('用系统看图打开'), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-zoom-fit')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('preview-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('preview-overlay')), findsNothing);
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
    await tester.scrollUntilVisible(
      find.text('窗口自适应'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('窗口自适应'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('游戏模式'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('游戏模式'), findsOneWidget);
    expect(find.text('暂停双击唤醒，其它功能仍可用'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('My ClipHist'), findsOneWidget);
  });

  test('acrylic theme uses a translucent scaffold', () {
    final opaque = cliphistTheme();
    final acrylic = cliphistTheme(acrylic: true);
    expect(opaque.scaffoldBackgroundColor, CliphistColors.bgBase);
    expect(acrylic.scaffoldBackgroundColor.a, greaterThan(0.7));
    expect(acrylic.scaffoldBackgroundColor.a, lessThan(1));
  });

  testWidgets('settings slides in and back returns to history', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith((ref) => layoutSettings),
        historyProvider.overrideWith((ref) => testHistory),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: cliphistTheme(), home: const MainScreen()),
      ),
    );
    await tester.pump();
    expect(find.text('剪贴板历史'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('设置'), findsWidgets);

    await tester.pumpAndSettle();
    expect(find.text('窗口自适应'), findsOneWidget);
    expect(find.text('静默启动'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('history')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings')), findsNothing);
    expect(find.text('剪贴板历史'), findsOneWidget);
    expect(find.byKey(const ValueKey('history')), findsOneWidget);
  });

  testWidgets('adaptive mode scales UI with window width', (tester) async {
    tester.view.physicalSize = const Size(540, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith((ref) => layoutSettings),
          historyProvider.overrideWith((ref) => testHistory),
        ],
        child: const ClipHistApp(),
      ),
    );
    await tester.pump();
    final scaler = MediaQuery.textScalerOf(tester.element(find.text('剪贴板历史')));
    expect(scaler.scale(1), closeTo(1.35, 0.01));
  });

  testWidgets('history and settings layout across common window sizes', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const sizes = <Size>[
      Size(320, 400),
      Size(400, 600),
      Size(600, 800),
      Size(800, 1000),
    ];
    for (final size in sizes) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith((ref) => layoutSettings),
            historyProvider.overrideWith((ref) => testHistory),
          ],
          child: const ClipHistApp(),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'history $size');
      expect(find.text('剪贴板历史'), findsOneWidget);

      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith((ref) => layoutSettings),
          settingsOpenProvider.overrideWith((ref) => true),
          historyProvider.overrideWith((ref) => testHistory),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ClipHistApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'settings $size');
      expect(find.text('设置'), findsWidgets);
    }
  });
}
