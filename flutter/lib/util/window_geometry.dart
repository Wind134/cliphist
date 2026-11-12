import 'dart:ui' show Offset, Rect, Size;

/// Pure window geometry helpers so restore/scale logic can be tested without
/// `window_manager` or a native display.
class WindowGeometry {
  WindowGeometry._();

  static const Size designSize = Size(400, 600);
  static const Size minSize = Size(320, 400);
  static const Size maxSize = Size(9999, 9999);
  static const double minVisibleOverlap = 80;
  static const double minAdaptiveScale = 0.85;
  static const double maxAdaptiveScale = 1.35;

  static Size clampSize(double width, double height) {
    return Size(
      width.clamp(minSize.width, maxSize.width),
      height.clamp(minSize.height, maxSize.height),
    );
  }

  /// Width-based scale so extra height still yields more list rows.
  /// Clamped so a previously large window does not 2× the whole UI.
  ///
  /// Continuous fractions (1.173× …) rasterize CJK at non-integer px and look
  /// soft on Windows. Snap to 0.05 and keep a dead zone around 1.0 so a
  /// slightly-resized window stays sharp.
  static double adaptiveScale({
    required double windowWidth,
    required double zoomLevel,
    required bool adaptive,
  }) {
    final zoom = zoomLevel.clamp(0.5, 2.0);
    if (!adaptive) return zoom;
    final raw = (windowWidth / designSize.width).clamp(
      minAdaptiveScale,
      maxAdaptiveScale,
    );
    return (zoom * _snapUiScale(raw)).clamp(0.5, 2.0);
  }

  static double _snapUiScale(double scale) {
    if (scale >= 0.97 && scale <= 1.06) return 1.0;
    return (scale * 20).round() / 20.0;
  }

  static bool isUsablePosition(Offset pos, Size window, List<Rect> displays) {
    if (displays.isEmpty) return true;
    final windowRect = pos & window;
    for (final display in displays) {
      final hit = windowRect.intersect(display);
      if (hit.width >= minVisibleOverlap && hit.height >= minVisibleOverlap) {
        return true;
      }
    }
    return false;
  }
}
