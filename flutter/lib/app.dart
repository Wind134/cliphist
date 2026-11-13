import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller.dart';
import 'state/providers.dart';
import 'ui/history_view.dart';
import 'ui/settings_screen.dart';
import 'ui/theme.dart';
import 'util/window_geometry.dart';

class ClipHistApp extends ConsumerWidget {
  const ClipHistApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final acrylic = Platform.isWindows && settings.acrylicEnabled;
    final mode = switch (settings.themeMode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    return MaterialApp(
      title: 'My ClipHist',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light, acrylic: acrylic),
      darkTheme: buildTheme(Brightness.dark, acrylic: acrylic),
      themeMode: mode,
      builder: (context, child) => LayoutBuilder(
        builder: (context, constraints) {
          final scale = WindowGeometry.adaptiveScale(
            windowWidth: constraints.maxWidth,
            zoomLevel: settings.zoomLevel,
            adaptive: settings.windowAdaptive,
          );
          return MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          );
        },
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends ConsumerWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsOpen = ref.watch(settingsOpenProvider);
    final toast = ref.watch(toastMessageProvider);
    final c = context.c;

    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.escape): const _EscapeIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.comma):
            const _SettingsIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.comma):
            const _SettingsIntent(),
      },
      child: Actions(
        actions: {
          _EscapeIntent: CallbackAction<_EscapeIntent>(
            onInvoke: (_) {
              unawaited(ClipHistController.instance.onEscape());
              return null;
            },
          ),
          _SettingsIntent: CallbackAction<_SettingsIntent>(
            onInvoke: (_) {
              ref.read(settingsOpenProvider.notifier).state = true;
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            body: SafeArea(
              child: Stack(
                children: [
                  MainPane(settingsOpen: settingsOpen),
                  if (toast.isNotEmpty)
                    _ToastOverlay(
                      message: toast,
                      invertedBg: c.text,
                      invertedFg: c.bg,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MainPane extends StatelessWidget {
  const MainPane({super.key, required this.settingsOpen});

  final bool settingsOpen;

  static const Duration switchDuration = Duration(milliseconds: 320);

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: switchDuration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          fit: StackFit.expand,
          children: [...previousChildren, ?currentChild],
        );
      },
      transitionBuilder: (child, animation) {
        final isSettings = child.key == const ValueKey('settings');
        final slide = Tween<Offset>(
          begin: isSettings ? const Offset(0.08, 0) : const Offset(-0.06, 0),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: slide, child: child),
        );
      },
      child: settingsOpen
          ? const SettingsScreen(key: ValueKey('settings'))
          : const HistoryView(key: ValueKey('history')),
    );
  }
}

class _EscapeIntent extends Intent {
  const _EscapeIntent();
}

class _SettingsIntent extends Intent {
  const _SettingsIntent();
}

class _ToastOverlay extends StatelessWidget {
  const _ToastOverlay({
    required this.message,
    required this.invertedBg,
    required this.invertedFg,
  });
  final String message;
  final Color invertedBg;
  final Color invertedFg;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 42,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: invertedBg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            message,
            style: TextStyle(color: invertedFg, fontSize: 12, height: 1.3),
          ),
        ),
      ),
    );
  }
}
