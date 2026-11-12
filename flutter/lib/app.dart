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
    return MaterialApp(
      title: 'My ClipHist',
      debugShowCheckedModeBanner: false,
      theme: cliphistTheme(acrylic: acrylic),
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

/// App shell: hosts the history/settings transition, Escape shortcut and toast.
/// The OS-native title bar already carries the window title, so there is no
/// separate in-app top bar.
class MainScreen extends ConsumerWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsOpen = ref.watch(settingsOpenProvider);
    final toast = ref.watch(toastMessageProvider);

    return Shortcuts(
      shortcuts: {LogicalKeySet(LogicalKeyboardKey.escape): _EscapeIntent()},
      child: Actions(
        actions: {
          _EscapeIntent: CallbackAction<_EscapeIntent>(
            onInvoke: (_) {
              unawaited(ClipHistController.instance.onEscape());
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
                  if (toast.isNotEmpty) _ToastOverlay(message: toast),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One page at a time: settings slides in from the right, history slides back
/// on close. No overlay, so the close/back control always receives taps.
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

class _ToastOverlay extends StatelessWidget {
  const _ToastOverlay({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 44,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: const Color(0xFF1B1F24).withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(CliphistColors.radius),
            boxShadow: const [
              BoxShadow(
                color: Color(0x29000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Text(
            message,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}
