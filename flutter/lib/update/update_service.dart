import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

enum UpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  applying,
  failed,
}

class UpdateInstaller {
  const UpdateInstaller({required this.name, required this.url});

  final String name;
  final Uri url;
}

class AppUpdateState {
  const AppUpdateState({
    required this.phase,
    this.currentVersion = '',
    this.latestVersion = '',
    this.releaseUrl,
    this.installer,
    this.downloadProgress = 0,
    this.errorMessage = '',
  });

  const AppUpdateState.idle() : this(phase: UpdatePhase.idle);

  final UpdatePhase phase;
  final String currentVersion;
  final String latestVersion;
  final Uri? releaseUrl;
  final UpdateInstaller? installer;
  final double downloadProgress;
  final String errorMessage;

  bool get hasUpdate =>
      phase == UpdatePhase.available ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.applying;

  bool get canInstallInApp => installer != null;

  AppUpdateState copyWith({
    UpdatePhase? phase,
    String? currentVersion,
    String? latestVersion,
    Uri? releaseUrl,
    UpdateInstaller? installer,
    double? downloadProgress,
    String? errorMessage,
  }) {
    return AppUpdateState(
      phase: phase ?? this.phase,
      currentVersion: currentVersion ?? this.currentVersion,
      latestVersion: latestVersion ?? this.latestVersion,
      releaseUrl: releaseUrl ?? this.releaseUrl,
      installer: installer ?? this.installer,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class UpdateService {
  UpdateService({
    HttpClient? client,
    Uri? latestReleaseApi,
    this.timeout = const Duration(seconds: 10),
    this.downloadTimeout = const Duration(minutes: 5),
  }) : _latestReleaseApi = latestReleaseApi ?? _defaultLatestReleaseApi,
       _client = client ?? HttpClient(),
       _ownsClient = client == null;

  static final Uri _defaultLatestReleaseApi = Uri.https(
    'api.github.com',
    '/repos/Wind134/cliphist/releases/latest',
  );

  static const int _maxResponseBytes = 1024 * 1024;
  static const int _maxInstallerBytes = 250 * 1024 * 1024;

  final HttpClient _client;
  final bool _ownsClient;
  final Uri _latestReleaseApi;
  final Duration timeout;
  final Duration downloadTimeout;

  Future<AppUpdateState> check({
    String? currentVersion,
    String? operatingSystem,
  }) async {
    var installed = currentVersion ?? '';
    try {
      if (installed.isEmpty) {
        installed = (await PackageInfo.fromPlatform()).version;
      }
      _client.connectionTimeout = timeout;
      final request = await _client.getUrl(_latestReleaseApi).timeout(timeout);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'MyClipHist/$installed')
        ..set('X-GitHub-Api-Version', '2026-03-10');
      // Each service instance performs one request. Disabling keep-alive lets
      // us reject an error status immediately without draining an arbitrary
      // or never-ending response body merely to recycle the connection.
      request.persistentConnection = false;
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GitHub Releases 返回 ${response.statusCode}',
          uri: _latestReleaseApi,
        );
      }
      final payload = utf8.decode(
        await _readBoundedResponse(response, timeout, _maxResponseBytes),
      );
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
      final installer = available
          ? pickInstaller(
              json['assets'],
              operatingSystem ?? Platform.operatingSystem,
            )
          : null;
      return AppUpdateState(
        phase: available ? UpdatePhase.available : UpdatePhase.upToDate,
        currentVersion: normalizeVersion(installed),
        latestVersion: latest,
        releaseUrl: url,
        installer: installer,
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

  /// Download [installer] to a temp file. [onProgress] receives 0–1.
  Future<File> downloadInstaller({
    required UpdateInstaller installer,
    required String version,
    void Function(double progress)? onProgress,
    Directory? directory,
  }) async {
    try {
      assertGithubDownload(installer.url);
      final dir = directory ?? Directory.systemTemp;
      final dest = File(
        '${dir.path}${Platform.pathSeparator}${_downloadFileName(version, installer.name)}',
      );
      _client.connectionTimeout = timeout;
      final request = await _client.getUrl(installer.url).timeout(timeout);
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'MyClipHist/$version')
        ..set(HttpHeaders.acceptHeader, 'application/octet-stream');
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.persistentConnection = false;
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          '下载安装包失败（${response.statusCode}）',
          uri: installer.url,
        );
      }
      if (response.contentLength > _maxInstallerBytes) {
        throw const FormatException('安装包超过大小限制');
      }
      final sink = dest.openWrite();
      var received = 0;
      final elapsed = Stopwatch()..start();
      try {
        final iterator = StreamIterator<List<int>>(response);
        try {
          while (true) {
            final remaining = downloadTimeout - elapsed.elapsed;
            if (remaining <= Duration.zero) {
              throw TimeoutException('下载安装包超时', downloadTimeout);
            }
            final hasChunk = await iterator.moveNext().timeout(remaining);
            if (!hasChunk) break;
            final chunk = iterator.current;
            received += chunk.length;
            if (received > _maxInstallerBytes) {
              throw const FormatException('安装包超过大小限制');
            }
            sink.add(chunk);
            final total = response.contentLength;
            if (total > 0) {
              onProgress?.call((received / total).clamp(0.0, 1.0));
            }
          }
        } finally {
          await iterator.cancel();
        }
        await sink.flush();
      } catch (_) {
        await sink.close();
        try {
          await dest.delete();
        } catch (_) {}
        rethrow;
      }
      await sink.close();
      onProgress?.call(1);
      return dest;
    } finally {
      if (_ownsClient) _client.close(force: true);
    }
  }

  /// Windows: launch the Inno Setup installer silently. macOS: open the DMG.
  /// The caller should quit the app on Windows after this returns.
  static Future<void> applyDownloadedInstaller(File file) async {
    if (!file.existsSync()) {
      throw Exception('安装包不存在');
    }
    if (Platform.isWindows) {
      await Process.start(
        file.path,
        const ['/VERYSILENT', '/NORESTART', '/CLOSEAPPLICATIONS', '/SP-'],
        mode: ProcessStartMode.detached,
      );
      return;
    }
    if (Platform.isMacOS) {
      final result = await Process.run('open', [file.path]);
      if (result.exitCode != 0) {
        throw Exception('无法打开安装包: ${result.stderr}');
      }
      return;
    }
    throw Exception('当前系统不支持应用内安装');
  }

  static Future<void> openRelease(Uri uri) async {
    if (uri.scheme != 'https' || uri.host != 'github.com') {
      throw const FormatException('拒绝打开非 GitHub 发布链接');
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) throw Exception('无法打开默认浏览器');
  }

  static void assertGithubDownload(Uri uri) {
    if (uri.scheme != 'https' || uri.host != 'github.com') {
      throw const FormatException('拒绝下载非 GitHub 安装包');
    }
  }

  static String _downloadFileName(String version, String assetName) {
    var base = assetName.replaceAll('\\', '/');
    if (base.contains('/')) {
      base = base.split('/').last;
    }
    if (base.isEmpty ||
        base == '.' ||
        base == '..' ||
        base.contains('\x00') ||
        base.contains(Platform.pathSeparator)) {
      throw const FormatException('安装包文件名无效');
    }
    return 'my-cliphist-$version-$base';
  }

  /// Choose a platform installer from a GitHub Releases `assets` array.
  /// Windows prefers a setup `.exe` (not MSIX); macOS wants a `.dmg`.
  /// Linux returns null — in-app install is not offered.
  static UpdateInstaller? pickInstaller(
    Object? assets,
    String operatingSystem,
  ) {
    if (assets is! List) return null;
    final files = <({String name, Uri url})>[];
    for (final raw in assets) {
      if (raw is! Map) continue;
      final name = (raw['name'] as String? ?? '').trim();
      final url = Uri.tryParse(
        raw['browser_download_url'] as String? ?? '',
      );
      if (name.isEmpty ||
          url == null ||
          url.scheme != 'https' ||
          url.host != 'github.com') {
        continue;
      }
      files.add((name: name, url: url));
    }
    if (files.isEmpty) return null;

    bool match(String name, List<String> suffixes, {List<String>? exclude}) {
      final lower = name.toLowerCase();
      if (exclude != null && exclude.any(lower.contains)) return false;
      return suffixes.any(lower.endsWith);
    }

    ({String name, Uri url})? firstWhere(bool Function(String name) test) {
      for (final file in files) {
        if (test(file.name)) return file;
      }
      return null;
    }

    final picked = switch (operatingSystem) {
      'windows' =>
        firstWhere(
          (name) =>
              match(name, ['.exe'], exclude: ['msix']) &&
              name.toLowerCase().contains('setup'),
        ) ??
        firstWhere((name) => match(name, ['.exe'], exclude: ['msix'])),
      'macos' => firstWhere((name) => match(name, ['.dmg'])),
      _ => null,
    };
    if (picked == null) return null;
    return UpdateInstaller(name: picked.name, url: picked.url);
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

  /// Read the response under one total deadline. `Stream.timeout` only limits
  /// the gap between chunks, so a trickle response could otherwise continue
  /// forever. `StreamIterator.cancel` also closes the HTTP subscription when
  /// a size or time limit is hit.
  static Future<Uint8List> _readBoundedResponse(
    HttpClientResponse response,
    Duration timeout,
    int maxBytes,
  ) async {
    final bytes = BytesBuilder(copy: false);
    final iterator = StreamIterator<List<int>>(response);
    final elapsed = Stopwatch()..start();
    try {
      if (response.contentLength > maxBytes) {
        throw const FormatException('更新响应超过大小限制');
      }
      while (true) {
        final remaining = timeout - elapsed.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('更新响应读取超时', timeout);
        }
        final hasChunk = await iterator.moveNext().timeout(remaining);
        if (!hasChunk) break;
        final chunk = iterator.current;
        if (bytes.length + chunk.length > maxBytes) {
          throw const FormatException('更新响应超过大小限制');
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } finally {
      await iterator.cancel();
    }
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
