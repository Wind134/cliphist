import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller.dart';
import 'state/providers.dart';
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
    final helper = ref.watch(helperConnectedProvider);

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
              child: Column(
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
                        : _HistoryPlaceholder(helperConnected: helper),
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

class _HistoryPlaceholder extends StatelessWidget {
  const _HistoryPlaceholder({required this.helperConnected});
  final bool helperConnected;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.history, size: 40, color: CliphistColors.textTertiary),
            const SizedBox(height: 12),
            const Text(
              'M4 历史 UI 待移植',
              style: TextStyle(color: CliphistColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Text(
              helperConnected ? 'evdev 双击: 已授权' : 'evdev 双击: 未连接',
              style: const TextStyle(
                color: CliphistColors.textTertiary,
                fontSize: 11,
              ),
            ),
          ],
        ),
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