import 'package:cliphist/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UpdateService.compareVersions', () {
    test('compares numeric segments instead of lexically', () {
      expect(UpdateService.compareVersions('2.10.0', '2.9.9'), greaterThan(0));
      expect(UpdateService.compareVersions('2.0.7', '2.0.7'), 0);
      expect(UpdateService.compareVersions('2.0', '2.0.0'), 0);
    });

    test('normalizes tags and build metadata', () {
      expect(
        UpdateService.compareVersions('v2.0.8', '2.0.7+42'),
        greaterThan(0),
      );
      expect(UpdateService.normalizeVersion(' V2.0.7+18 '), '2.0.7');
    });

    test('orders prereleases below stable releases', () {
      expect(
        UpdateService.compareVersions('2.1.0-beta.2', '2.1.0'),
        lessThan(0),
      );
      expect(
        UpdateService.compareVersions('2.1.0-beta.10', '2.1.0-beta.2'),
        greaterThan(0),
      );
    });
  });
}
