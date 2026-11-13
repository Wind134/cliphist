import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/stream.dart' as api_stream;
import '../src/rust/core/clipboard_engine.dart' show ClipboardItem;
import '../state/history_provider.dart';
import '../util/image_cache.dart';

/// Subscribe the three history-bearing Rust streams to the Riverpod
/// [historyProvider]. Called once from [ClipHistController.start]; the
/// returned subscriptions remain alive until the process exits.
///
///  - `clipboardChanged`: top-5 snapshot after a new entry is recorded. Merge
///    by id (new items win, duplicates deduped) and cap at 500.
///  - `historyReplace`: full snapshot pushed by deletion, retention, clear,
///    or a capture that trims multiple tail entries.
///    Swap wholesale and drop the image cache (ids may be stale).
///  - `itemMovedToTop`: one id floated to the front (quick-paste path).
///    Rotate it to index 0 locally so the UI reorders before the next poll.
List<StreamSubscription<dynamic>> subscribeClipboardStreams(
  ProviderContainer container,
) {
  final subs = <StreamSubscription<dynamic>>[];

  subs.add(
    api_stream.streamClipboardChanged().listen((top5) {
      final cur = container.read(historyProvider);
      final topIds = top5.map((t) => t.id).toSet();
      final rest = cur.where((hi) => !topIds.contains(hi.id)).toList();
      final merged = [...top5, ...rest];
      container.read(historyProvider.notifier).state = merged.length > 500
          ? merged.sublist(0, 500)
          : merged;
    }),
  );

  subs.add(
    api_stream.streamHistoryReplace().listen((full) {
      container.read(historyProvider.notifier).state = full;
      clearImageCache();
    }),
  );

  subs.add(
    api_stream.streamItemMovedToTop().listen((id) {
      final cur = container.read(historyProvider);
      final i = cur.indexWhere((x) => x.id == id);
      if (i < 0) return;
      final nh = [...cur];
      final it = nh.removeAt(i);
      nh.insert(0, _stampNow(it));
      container.read(historyProvider.notifier).state = nh;
    }),
  );

  return subs;
}

String _nowStamp() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
}

ClipboardItem _stampNow(ClipboardItem it) {
  return ClipboardItem(
    id: it.id,
    content: it.content,
    contentType: it.contentType,
    timestamp: _nowStamp(),
    preview: it.preview,
    charCount: it.charCount,
    imagePath: it.imagePath,
    imageWidth: it.imageWidth,
    imageHeight: it.imageHeight,
    htmlContent: it.htmlContent,
    filePaths: it.filePaths,
    contentHash: it.contentHash,
  );
}
