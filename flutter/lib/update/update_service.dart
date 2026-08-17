import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

enum UpdatePhase { idle, checking, upToDate, available, failed }

class AppUpdateState {
  const AppUpdateState({
    required this.phase,
    this.currentVersion = '',
    this.latestVersion = '',
    this.releaseUrl,
    this.errorMessage = '',
  });

  const AppUpdateState.idle() : this(phase: UpdatePhase.idle);

  final UpdatePhase phase;
  final String currentVersion;
  final String latestVersion;
  final Uri? releaseUrl;
  final String errorMessage;

  bool get hasUpdate => phase == UpdatePhase.available;
}

class UpdateService {
  UpdateService({HttpClient? client})
    : _client = client ?? HttpClient(),
      _ownsClient = client == null;

  static final Uri _latestReleaseApi = Uri.https(
    'api.github.com',
    '/repos/Wind134/cliphist/releases/latest',
  );

  final HttpClient _client;
  final bool _ownsClient;

  Future<AppUpdateState> check({String? currentVersion}) async {
    var installed = currentVersion ?? '';
    try {
      if (installed.isEmpty) {
        installed = (await PackageInfo.fromPlatform()).version;
      }
      _client.connectionTimeout = const Duration(seconds: 8);
      final request = await _client
          .getUrl(_latestReleaseApi)
          .timeout(const Duration(seconds: 10));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'ClipHist/$installed')
        ..set('X-GitHub-Api-Version', '2026-03-10');
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          'GitHub Releases 返回 ${response.statusCode}',
          uri: _latestReleaseApi,
        );
      }
      final payload = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      final json = jsonDecode(payload);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('更新响应不是 JSON 对象');
      }

      final tag = (json['tag_name'] as String? ?? '').trim();
      final url = Uri.tryParse(json['html_url'] as String? ?? '');
      if (tag.isEmpty ||
          url == null ||
          url.scheme != 'https' ||
          url.host != 'github.com') {
        throw const FormatException('更新响应缺少有效的版本或发布链接');
      }

      final latest = normalizeVersion(tag);
      final available = compareVersions(latest, installed) > 0;
      return AppUpdateState(
        phase: available ? UpdatePhase.available : UpdatePhase.upToDate,
        currentVersion: normalizeVersion(installed),
        latestVersion: latest,
        releaseUrl: url,
      );
    } catch (error) {
      return AppUpdateState(
        phase: UpdatePhase.failed,
        currentVersion: normalizeVersion(installed),
        errorMessage: _friendlyError(error),
      );
    } finally {
      if (_ownsClient) _client.close(force: true);
    }
  }

  static Future<void> openRelease(Uri uri) async {
    if (uri.scheme != 'https' || uri.host != 'github.com') {
      throw const FormatException('拒绝打开非 GitHub 发布链接');
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) throw Exception('无法打开默认浏览器');
  }

  static String normalizeVersion(String input) {
    var value = input.trim();
    if (value.toLowerCase().startsWith('v')) value = value.substring(1);
    return value.split('+').first;
  }

  /// Semantic-version comparison with numeric core segments and conventional
  /// prerelease ordering. Returns > 0 when [left] is newer than [right].
  static int compareVersions(String left, String right) {
    final a = _ParsedVersion.parse(left);
    final b = _ParsedVersion.parse(right);
    final length = a.core.length > b.core.length
        ? a.core.length
        : b.core.length;
    for (var i = 0; i < length; i++) {
      final av = i < a.core.length ? a.core[i] : 0;
      final bv = i < b.core.length ? b.core[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    if (a.pre.isEmpty && b.pre.isNotEmpty) return 1;
    if (a.pre.isNotEmpty && b.pre.isEmpty) return -1;
    for (var i = 0; i < a.pre.length || i < b.pre.length; i++) {
      if (i >= a.pre.length) return -1;
      if (i >= b.pre.length) return 1;
      final ai = int.tryParse(a.pre[i]);
      final bi = int.tryParse(b.pre[i]);
      if (ai != null && bi != null && ai != bi) return ai.compareTo(bi);
      if (ai != null && bi == null) return -1;
      if (ai == null && bi != null) return 1;
      final lexical = a.pre[i].compareTo(b.pre[i]);
      if (lexical != 0) return lexical;
    }
    return 0;
  }

  static String _friendlyError(Object error) {
    if (error is TimeoutException) return '连接超时，请检查网络后重试';
    if (error is SocketException) return '无法连接更新服务';
    return error.toString().replaceFirst('Exception: ', '');
  }
}

class _ParsedVersion {
  const _ParsedVersion(this.core, this.pre);

  final List<int> core;
  final List<String> pre;

  factory _ParsedVersion.parse(String value) {
    final normalized = UpdateService.normalizeVersion(value);
    final dash = normalized.indexOf('-');
    final corePart = dash < 0 ? normalized : normalized.substring(0, dash);
    final prePart = dash < 0 ? '' : normalized.substring(dash + 1);
    final core = corePart
        .split('.')
        .map((part) {
          final match = RegExp(r'^\d+').firstMatch(part);
          return int.tryParse(match?.group(0) ?? '') ?? 0;
        })
        .toList(growable: false);
    final pre = prePart.isNotEmpty
        ? prePart.split('.').where((part) => part.isNotEmpty).toList()
        : const <String>[];
    return _ParsedVersion(core, pre);
  }
}
