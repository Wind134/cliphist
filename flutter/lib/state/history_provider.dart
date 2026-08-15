import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/history.dart' as api_history;
import '../src/rust/core/clipboard_engine.dart' show ClipboardItem;

/// Full in-memory history. Seeded synchronously from [api_history.getHistory]
/// (the Rust core already loaded `history.json` during `initAppState`); the
/// three clipboard streams merge / replace / reorder it afterwards. Mirrors the
/// old Svelte `history` store.
final historyProvider = StateProvider<List<ClipboardItem>>(
  (ref) => api_history.getHistory(),
);

/// Index into [filteredHistoryProvider] of the highlighted row, or -1.
/// Reset to -1 when the search query or category changes (matches the old
/// Svelte behavior where refiltering invalidates the selection).
final selectedIndexProvider = StateProvider<int>((ref) => -1);

/// Live search-box text.
final searchQueryProvider = StateProvider<String>((ref) => '');

/// Active category tab: one of `all|image|text|link|short|rich`.
final currentCategoryProvider = StateProvider<String>((ref) => 'all');

/// Derive the visible rows from the full history + query + category. A
/// non-empty query substring-filters on `content` (case-insensitive), after
/// the category filter. `Provider` (not `StateProvider`) so it never holds
/// stale state.
final filteredHistoryProvider = Provider<List<ClipboardItem>>((ref) {
  final hist = ref.watch(historyProvider);
  final cat = ref.watch(currentCategoryProvider);
  final query = ref.watch(searchQueryProvider);

  var items = hist;
  if (cat != 'all') {
    items = items.where((i) => i.contentType == cat).toList();
  }
  if (query.isNotEmpty) {
    final q = query.toLowerCase();
    items = items.where((i) => i.content.toLowerCase().contains(q)).toList();
  }
  return items;
});