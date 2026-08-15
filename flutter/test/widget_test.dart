import 'package:flutter_test/flutter_test.dart';

import 'package:cliphist/ui/theme.dart';

void main() {
  test('cliphist theme builds without error', () {
    expect(cliphistTheme(), isNotNull);
    expect(CliphistColors.bgPrimary, isNotEmpty);
  });
}
