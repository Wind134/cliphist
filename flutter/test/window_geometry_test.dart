import 'dart:ui';

import 'package:cliphist/util/window_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clampSize enforces the window min and max', () {
    expect(WindowGeometry.clampSize(100, 100), WindowGeometry.minSize);
    expect(WindowGeometry.clampSize(400, 600), const Size(400, 600));
    expect(WindowGeometry.clampSize(20000, 20000), WindowGeometry.maxSize);
  });

  test('adaptive scale is 1.0 at the design width', () {
    expect(
      WindowGeometry.adaptiveScale(
        windowWidth: 400,
        zoomLevel: 1,
        adaptive: true,
      ),
      1.0,
    );
  });

  test('adaptive scale grows with width but stays capped', () {
    expect(
      WindowGeometry.adaptiveScale(
        windowWidth: 540,
        zoomLevel: 1,
        adaptive: true,
      ),
      1.35,
    );
    expect(
      WindowGeometry.adaptiveScale(
        windowWidth: 800,
        zoomLevel: 1,
        adaptive: true,
      ),
      WindowGeometry.maxAdaptiveScale,
    );
  });

  test('adaptive scale stays 1.0 near the design width', () {
    expect(
      WindowGeometry.adaptiveScale(
        windowWidth: 420,
        zoomLevel: 1,
        adaptive: true,
      ),
      1.0,
    );
  });

  test('adaptive scale does not shrink below the floor', () {
    expect(
      WindowGeometry.adaptiveScale(
        windowWidth: 320,
        zoomLevel: 1,
        adaptive: true,
      ),
      WindowGeometry.minAdaptiveScale,
    );
  });

  test('manual zoom is unchanged when adaptive is off', () {
    expect(
      WindowGeometry.adaptiveScale(
        windowWidth: 800,
        zoomLevel: 1.2,
        adaptive: false,
      ),
      1.2,
    );
  });

  test('adaptive scale still multiplies the manual zoom', () {
    expect(
      WindowGeometry.adaptiveScale(
        windowWidth: 400,
        zoomLevel: 1.5,
        adaptive: true,
      ),
      1.5,
    );
  });

  test('a window fully on a display is usable', () {
    const display = Rect.fromLTWH(0, 0, 1920, 1080);
    expect(
      WindowGeometry.isUsablePosition(
        const Offset(100, 80),
        const Size(400, 600),
        [display],
      ),
      isTrue,
    );
  });

  test('a window parked off every display is not usable', () {
    const display = Rect.fromLTWH(0, 0, 1920, 1080);
    expect(
      WindowGeometry.isUsablePosition(
        const Offset(-800, -800),
        const Size(400, 600),
        [display],
      ),
      isFalse,
    );
  });

  test('unknown displays do not reject a saved position', () {
    expect(
      WindowGeometry.isUsablePosition(
        const Offset(-200, 40),
        const Size(400, 600),
        const [],
      ),
      isTrue,
    );
  });

  test('a window straddling a second monitor remains usable', () {
    const primary = Rect.fromLTWH(0, 0, 1920, 1080);
    const secondary = Rect.fromLTWH(1920, 0, 1440, 900);
    expect(
      WindowGeometry.isUsablePosition(
        const Offset(1800, 100),
        const Size(400, 600),
        [primary, secondary],
      ),
      isTrue,
    );
  });
}
