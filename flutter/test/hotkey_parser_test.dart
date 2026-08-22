import 'package:cliphist/util/hotkey_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseHotKey', () {
    test('accepts the same named keys and aliases as the Rust validator', () {
      expect(() => parseHotKey('Ctrl+Shift+V'), returnsNormally);
      expect(() => parseHotKey('Control+Backspace'), returnsNormally);
      expect(() => parseHotKey('Option+F12'), returnsNormally);
      expect(() => parseHotKey('Meta+Enter'), returnsNormally);
    });

    test('rejects empty, duplicate, unknown, or multiple keys', () {
      for (final shortcut in [
        '',
        'V',
        'Ctrl++V',
        'Ctrl+Ctrl+V',
        'Ctrl+Unknown',
        'Ctrl+V+X',
      ]) {
        expect(
          () => parseHotKey(shortcut),
          throwsFormatException,
          reason: shortcut,
        );
      }
    });
  });
}
