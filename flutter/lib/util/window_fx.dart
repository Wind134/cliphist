import 'dart:io';

import 'package:flutter/services.dart';

/// Windows-only DWM acrylic/mica control. Other platforms no-op.
class WindowFx {
  WindowFx._();

  static const MethodChannel channel = MethodChannel('cliphist/window_fx');

  static bool get isSupported => Platform.isWindows;

  static Future<void> setAcrylic(bool enabled) async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod<void>('setAcrylic', enabled);
    } on MissingPluginException {
      // Widget tests and builds without the runner channel.
    } on PlatformException {
      // Older Windows builds may reject the DWM call.
    }
  }
}
