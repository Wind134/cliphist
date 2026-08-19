import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

/// Set the toast message and clear it automatically after two seconds. Any
/// caller can fire it via the shared [ProviderContainer].
Timer? _toastTimer;

void showToast(ProviderContainer container, String message) {
  container.read(toastMessageProvider.notifier).state = message;
  _toastTimer?.cancel();
  _toastTimer = Timer(const Duration(milliseconds: 2000), () {
    container.read(toastMessageProvider.notifier).state = '';
  });
}
