import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/stream.dart' as api_stream;
import '../state/history_provider.dart';
import '../util/image_cache.dart';

/// Subscribe the three history-bearing Rust streams to the Riverpod
/// [historyProvider]. Called once from [ClipHistController.start]; the
/// returned subscriptions are cancelled on quit.
///
///  - `clipboardChanged`: top-5 snapshot after a new entry is recorded. Merge
///    by id (new items win, duplicates deduped) and cap at 500 — faithful to
///    the old Svelte merge.
///  - `historyReplace`: full snapshot pushed by the retention sweep / clear.
///    Swap wholesale and drop the image cache (ids may be stale).
///  - `itemMovedToTop`: one id floated to the front (quick-paste path).
///    Rotate it to index 0 locally so the UI reorders before the next poll.
List<StreamSubscription> subscribeClipboardStreams(ProviderContainer container) {
  final subs = <StreamSubscription>[];

  subs.add(api_stream.streamClipboardChanged().listen((top5) {
    final cur = container.read(historyProvider);
    final topIds = top5.map((t) => t.id).toSet();
    final rest = cur.where((hi) => !topIds.contains(hi.id)).toList();
    final merged = [...top5, ...rest];
    container.read(historyProvider.notifier).state =
        merged.length > 500 ? merged.sublist(0, 500) : merged;
  }));

  subs.add(api_stream.streamHistoryReplace().listen((full) {
    container.read(historyProvider.notifier).state = full;
    clearImageCache();
  }));

  subs.add(api_stream.streamItemMovedToTop().listen((id) {
    final cur = container.read(historyProvider);
    final i = cur.indexWhere((x) => x.id == id);
    if (i <= 0) return;
    final nh = [...cur];
    final it = nh.removeAt(i);
    nh.insert(0, it);
    container.read(historyProvider.notifier).state = nh;
  }));

  return subs;
}