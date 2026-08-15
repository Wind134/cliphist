import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller.dart';
import 'state/providers.dart';
import 'ui/history_view.dart';
import 'ui/theme.dart';

class ClipHistApp extends ConsumerWidget {
  const ClipHistApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'ClipHist',
      debugShowCheckedModeBanner: false,
      theme: cliphistTheme(),
      home: const MainScreen(),
    );
  }
}

/// M3 app shell: minimal top bar + placeholder content + Escape handling.
/// The history list (M4) and settings panel (M5) replace the placeholders.
class MainScreen extends ConsumerWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsOpen = ref.watch(settingsOpenProvider);
    final settings = ref.watch(settingsProvider);
    final toast = ref.watch(toastMessageProvider);

    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.escape): _EscapeIntent(),
      },
      child: Actions(
        actions: {
          _EscapeIntent: CallbackAction<_EscapeIntent>(
            onInvoke: (_) => ClipHistController.instance.onEscape(),
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: CliphistColors.bgPrimary,
            body: SafeArea(
              child: Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TopBar(
                        title: settingsOpen ? '设置' : 'ClipHist',
                        onSettingsTap: () {
                          ref.read(settingsOpenProvider.notifier).state =
                              !settingsOpen;
                        },
                      ),
                      Expanded(
                        child: settingsOpen
                            ? _SettingsPlaceholder(settings: settings)
                            : const HistoryView(),
                      ),
                    ],
                  ),
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

class _TopBar extends StatelessWidget {
  const _TopBar({required this.title, required this.onSettingsTap});
  final String title;
  final VoidCallback onSettingsTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: CliphistColors.bgSecondary,
        border: Border(
          bottom: BorderSide(color: CliphistColors.border, width: 1),
        ),
      ),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: CliphistColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 18),
            color: CliphistColors.textSecondary,
            splashRadius: 16,
            onPressed: onSettingsTap,
          ),
        ],
      ),
    );
  }
}

class _SettingsPlaceholder extends StatelessWidget {
  const _SettingsPlaceholder({required this.settings});
  final dynamic settings;

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tune, size: 40, color: CliphistColors.textTertiary),
            SizedBox(height: 12),
            Text(
              'M5 设置 UI 待移植',
              style: TextStyle(color: CliphistColors.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
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
      bottom: 40,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: CliphistColors.textPrimary.withOpacity(0.9),
            borderRadius: BorderRadius.circular(CliphistColors.radius),
          ),
          child: Text(
            message,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ),
    );
  }
}