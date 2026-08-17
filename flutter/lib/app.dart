import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller.dart';
import 'state/providers.dart';
import 'ui/history_view.dart';
import 'ui/settings_screen.dart';
import 'ui/theme.dart';

class ClipHistApp extends ConsumerWidget {
  const ClipHistApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zoom = ref.watch(settingsProvider).zoomLevel;
    return MaterialApp(
      title: 'ClipHist',
      debugShowCheckedModeBanner: false,
      theme: cliphistTheme(),
      // Apply the persisted zoom level as a text scaler (preferred over
      // Transform.scale — keeps text crisp, reflows layout). The Svelte
      // version used CSS `transform: scale`; this is the Flutter analogue.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(zoom)),
        child: child!,
      ),
      home: const MainScreen(),
    );
  }
}

/// App shell: swaps between the history view and the settings panel, hosts
/// the Escape shortcut and the toast overlay. The OS-native title bar
/// (decision 3.6) already carries the window title, so there is no separate
/// in-app top bar — each screen owns its own chrome (the search row for the
/// history view, the header for settings).
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
            onInvoke: (_) => ClipHistController.instance.onEscape(),
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: CliphistColors.bgBase,
            body: SafeArea(
              child: Stack(
                children: [
                  settingsOpen ? const SettingsScreen() : const HistoryView(),
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
              fontSize: 12.5,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}
