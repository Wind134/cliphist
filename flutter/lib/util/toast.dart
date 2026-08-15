import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

/// Toast helper, ported from the old Svelte `toast` store: set the message,
/// auto-clear after 2s. Any caller can fire it via the shared [ProviderContainer].
Timer? _toastTimer;

void showToast(ProviderContainer container, String message) {
  container.read(toastMessageProvider.notifier).state = message;
  _toastTimer?.cancel();
  _toastTimer = Timer(const Duration(milliseconds: 2000), () {
    container.read(toastMessageProvider.notifier).state = '';
  });
}