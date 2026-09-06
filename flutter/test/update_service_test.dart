import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  group('UpdateService HTTP behavior', () {
    test('sends required headers and parses a valid release', () async {
      String? accept;
      String? userAgent;
      final endpoint = await _TestEndpoint.bind((request) {
        accept = request.headers.value(HttpHeaders.acceptHeader);
        userAgent = request.headers.value(HttpHeaders.userAgentHeader);
        unawaited(
          _respond(
            request,
            HttpStatus.ok,
            jsonEncode({
              'tag_name': 'v2.1.0',
              'html_url':
                  'https://github.com/Wind134/cliphist/releases/tag/v2.1.0',
            }),
          ),
        );
      });
      addTearDown(endpoint.close);

      final result = await UpdateService(
        latestReleaseApi: endpoint.uri,
      ).check(currentVersion: '2.0.7');

      expect(result.phase, UpdatePhase.available);
      expect(result.latestVersion, '2.1.0');
      expect(accept, 'application/vnd.github+json');
      expect(userAgent, 'MyClipHist/2.0.7');
    });

    test('turns a non-success response into a failed state', () async {
      final endpoint = await _TestEndpoint.bind((request) {
        unawaited(
          _respond(request, HttpStatus.tooManyRequests, 'rate limited'),
        );
      });
      addTearDown(endpoint.close);

      final result = await UpdateService(
        latestReleaseApi: endpoint.uri,
      ).check(currentVersion: '2.0.7');

      expect(result.phase, UpdatePhase.failed);
      expect(result.errorMessage, contains('429'));
    });

    test('rejects oversized responses', () async {
      final endpoint = await _TestEndpoint.bind((request) {
        unawaited(_respond(request, HttpStatus.ok, 'x' * (1024 * 1024 + 1)));
      });
      addTearDown(endpoint.close);

      final result = await UpdateService(
        latestReleaseApi: endpoint.uri,
      ).check(currentVersion: '2.0.7');

      expect(result.phase, UpdatePhase.failed);
      expect(result.errorMessage, contains('大小限制'));
    });

    test('reports a response timeout', () async {
      final endpoint = await _TestEndpoint.bind((request) {
        unawaited(_respondAfterDelay(request));
      });
      addTearDown(endpoint.close);

      final result = await UpdateService(
        latestReleaseApi: endpoint.uri,
        timeout: const Duration(milliseconds: 20),
      ).check(currentVersion: '2.0.7');

      expect(result.phase, UpdatePhase.failed);
      expect(result.errorMessage, contains('超时'));
    });

    test('applies one total deadline to a trickle response', () async {
      final endpoint = await _TestEndpoint.bind((request) {
        unawaited(_respondAsTrickle(request));
      });
      addTearDown(endpoint.close);

      final result = await UpdateService(
        latestReleaseApi: endpoint.uri,
        timeout: const Duration(milliseconds: 40),
      ).check(currentVersion: '2.0.7');

      expect(result.phase, UpdatePhase.failed);
      expect(result.errorMessage, contains('超时'));
    });
  });
}

Future<void> _respond(HttpRequest request, int status, String body) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(body);
  await request.response.close();
}

Future<void> _respondAfterDelay(HttpRequest request) async {
  await Future<void>.delayed(const Duration(milliseconds: 100));
  try {
    await _respond(request, HttpStatus.ok, '{}');
  } on HttpException {
    // The client intentionally timed out and closed first.
  }
}

Future<void> _respondAsTrickle(HttpRequest request) async {
  request.response
    ..statusCode = HttpStatus.ok
    ..headers.contentType = ContentType.json;
  try {
    for (var i = 0; i < 20; i++) {
      request.response.write(' ');
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await request.response.close();
  } on HttpException {
    // The client intentionally cancels the body subscription at its deadline.
  }
}

class _TestEndpoint {
  _TestEndpoint(this._server, this._subscription);

  final HttpServer _server;
  final StreamSubscription<HttpRequest> _subscription;

  Uri get uri =>
      Uri.parse('http://${_server.address.host}:${_server.port}/latest');

  static Future<_TestEndpoint> bind(void Function(HttpRequest) handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _TestEndpoint(server, server.listen(handler));
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }
}
