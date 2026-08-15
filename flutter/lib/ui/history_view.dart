import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_controller.dart';
import '../src/rust/api/clipboard.dart' as api_clipboard;
import '../src/rust/api/history.dart' as api_history;
import '../src/rust/core/clipboard_engine.dart' show ClipboardItem;
import '../state/history_provider.dart';
import '../state/providers.dart';
import '../util/image_cache.dart';
import '../util/toast.dart';
import 'category_tabs.dart';
import 'history_item.dart';
import 'status_bar.dart';
import 'theme.dart';

/// Full history screen (search + category tabs + toolbar + list + empty
/// states + keyboard nav), ported from `src/lib/history-list.svelte`.
///
/// Keyboard model (faithful to the Svelte version):
///  - When the search box is focused: ↑/↓ move selection, Enter copies the
///    selected row, Escape blurs the search box (does NOT hide the app).
///  - When the search box is NOT focused: digits 1-9 quick-paste the nth row.
///  - Arrow/Enter also work when the search is not focused (small UX nicety
///    on top of the original behavior).
class HistoryView extends ConsumerStatefulWidget {
  const HistoryView({super.key});

  @override
  ConsumerState<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends ConsumerState<HistoryView> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _viewFocus = FocusNode(debugLabel: 'history-view');
  final FocusNode _searchFocus = FocusNode(debugLabel: 'history-search');

  @override
  void initState() {
    super.initState();
    _searchFocus.onKeyEvent = _onSearchKeyEvent;
    _viewFocus.onKeyEvent = _onViewKeyEvent;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    _searchFocus.dispose();
    _viewFocus.dispose();
    super.dispose();
  }

  ProviderContainer get _container => ClipHistController.instance.container;

  List<ClipboardItem> get _filtered => ref.read(filteredHistoryProvider);

  void _onSearchQueryChanged(String q) {
    ref.read(searchQueryProvider.notifier).state = q;
    ref.read(selectedIndexProvider.notifier).state = -1;
  }

  void _onCategoryChanged(String cat) {
    ref.read(currentCategoryProvider.notifier).state = cat;
    ref.read(selectedIndexProvider.notifier).state = -1;
  }

  // ── Keyboard ────────────────────────────────────────────────────────────
  KeyEventResult _onSearchKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveSelection(-1);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _moveSelection(1);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.enter) {
      _handleEnter();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.escape) {
      // Blur search so the app-level Escape (hide/quit) takes over next.
      _viewFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onViewKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // 1-9 quick-paste (only when not typing into the search box).
    if (key == LogicalKeyboardKey.digit1) return _quickPaste(1);
    if (key == LogicalKeyboardKey.digit2) return _quickPaste(2);
    if (key == LogicalKeyboardKey.digit3) return _quickPaste(3);
    if (key == LogicalKeyboardKey.digit4) return _quickPaste(4);
    if (key == LogicalKeyboardKey.digit5) return _quickPaste(5);
    if (key == LogicalKeyboardKey.digit6) return _quickPaste(6);
    if (key == LogicalKeyboardKey.digit7) return _quickPaste(7);
    if (key == LogicalKeyboardKey.digit8) return _quickPaste(8);
    if (key == LogicalKeyboardKey.digit9) return _quickPaste(9);
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveSelection(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveSelection(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter) {
      _handleEnter();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Quick-paste the nth row (1-based). Returns `handled` if a row existed.
  KeyEventResult _quickPaste(int n) {
    final items = _filtered;
    if (n < 1 || n > items.length || n > 9) return KeyEventResult.ignored;
    final item = items[n - 1];
    ClipHistController.instance.quickPaste(item.id);
    return KeyEventResult.handled;
  }

  void _moveSelection(int delta) {
    final items = _filtered;
    if (items.isEmpty) return;
    int cur = ref.read(selectedIndexProvider);
    if (cur < 0) {
      cur = delta > 0 ? -1 : 0;
    }
    int next = (cur + delta).clamp(0, items.length - 1);
    ref.read(selectedIndexProvider.notifier).state = next;
    _ensureVisible(next);
  }

  void _ensureVisible(int index) {
    if (!_scrollCtrl.hasClients) return;
    const itemHeight = 84.0;
    final viewport = _scrollCtrl.position.viewportDimension;
    final offset = _scrollCtrl.offset;
    final target = index * itemHeight;
    if (target < offset) {
      _scrollCtrl.animateTo(
        target,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
      );
    } else if (target + itemHeight > offset + viewport) {
      _scrollCtrl.animateTo(
        target + itemHeight - viewport,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
      );
    }
  }

  void _handleEnter() {
    final items = _filtered;
    final idx = ref.read(selectedIndexProvider);
    if (idx < 0 || idx >= items.length) return;
    _copyItem(items[idx], hideAfter: true);
  }

  // ── Actions ────────────────────────────────────────────────────────────
  Future<void> _copyItem(ClipboardItem item, {bool hideAfter = false}) async {
    try {
      await api_clipboard.copyToClipboard(id: item.id);
      showToast(_container, '已复制');
    } catch (e) {
      showToast(_container, '复制失败: $e');
      return;
    }
    if (hideAfter) {
      final closeToTray = ref.read(settingsProvider).closeToTray;
      if (closeToTray) await ClipHistController.instance.hideWindow();
    }
  }

  Future<void> _deleteItem(ClipboardItem item) async {
    // Optimistic local removal — Rust `delete_item` does not emit a stream.
    final cur = ref.read(historyProvider);
    final nh = cur.where((x) => x.id != item.id).toList();
    ref.read(historyProvider.notifier).state = nh;
    evictImage(item.id);
    ref.read(selectedIndexProvider.notifier).state = -1;
    try {
      await api_history.deleteItem(id: item.id);
      showToast(_container, '已删除');
    } catch (e) {
      // Restore on failure.
      ref.read(historyProvider.notifier).state = cur;
      showToast(_container, '删除失败: $e');
    }
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空历史'),
        content: const Text('确定清空全部剪贴板历史？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api_history.clearHistory(); // emits history-replace([])
      showToast(_container, '已清空');
    } catch (e) {
      showToast(_container, '清空失败: $e');
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final filtered = ref.watch(filteredHistoryProvider);
    final selected = ref.watch(selectedIndexProvider);
    final query = ref.watch(searchQueryProvider);
    final category = ref.watch(currentCategoryProvider);
    final helper = ref.watch(helperConnectedProvider);

    return Focus(
      focusNode: _viewFocus,
      autofocus: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SearchBar(
            controller: _searchCtrl,
            focusNode: _searchFocus,
            value: query,
            onChanged: _onSearchQueryChanged,
          ),
          CategoryTabs(current: category, onChanged: _onCategoryChanged),
          _Toolbar(
            count: filtered.length,
            onClear: _clearAll,
            onSettings: () =>
                ref.read(settingsOpenProvider.notifier).state = true,
          ),
          Expanded(
            child: filtered.isEmpty
                ? _EmptyState(query: query, category: category)
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: EdgeInsets.zero,
                    itemCount: filtered.length,
                    itemExtentBuilder: (i, _) =>
                        filtered[i].contentType == 'image' ? 132 : 78,
                    itemBuilder: (ctx, i) => HistoryItem(
                      key: ValueKey(filtered[i].id),
                      item: filtered[i],
                      index: i + 1,
                      selected: i == selected,
                      onTap: () => ref
                          .read(selectedIndexProvider.notifier)
                          .state = i,
                      onDoubleTap: () =>
                          _copyItem(filtered[i], hideAfter: true),
                      onCopy: () => _copyItem(filtered[i]),
                      onDelete: () => _deleteItem(filtered[i]),
                    ),
                  ),
          ),
          StatusBar(helperConnected: helper, count: filtered.length),
        ],
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.value,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    if (controller.text != value) controller.text = value;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      color: CliphistColors.bgSecondary,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        style: const TextStyle(
          color: CliphistColors.textPrimary,
          fontSize: 13,
        ),
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索剪贴板历史…',
          hintStyle: const TextStyle(
            color: CliphistColors.textTertiary,
            fontSize: 13,
          ),
          prefixIcon: const Icon(Icons.search, size: 16),
          prefixIconConstraints: const BoxConstraints(minWidth: 32),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          filled: true,
          fillColor: CliphistColors.bgPrimary,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
            borderSide: const BorderSide(color: CliphistColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
            borderSide: const BorderSide(color: CliphistColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
            borderSide:
                const BorderSide(color: CliphistColors.accent, width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.count,
    required this.onClear,
    required this.onSettings,
  });

  final int count;
  final VoidCallback onClear;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: CliphistColors.bgSecondary,
      child: Row(
        children: [
          Text(
            '$count 条',
            style: const TextStyle(
              color: CliphistColors.textTertiary,
              fontSize: 11,
            ),
          ),
          const Spacer(),
          _ToolbarBtn(icon: Icons.delete_sweep_outlined, onTap: onClear),
          _ToolbarBtn(icon: Icons.settings_outlined, onTap: onSettings),
        ],
      ),
    );
  }
}

class _ToolbarBtn extends StatelessWidget {
  const _ToolbarBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      splashRadius: 14,
      icon: Icon(icon, size: 15),
      color: CliphistColors.textSecondary,
      onPressed: onTap,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.query, required this.category});
  final String query;
  final String category;

  @override
  Widget build(BuildContext context) {
    final hasFilter = query.isNotEmpty || category != 'all';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasFilter ? Icons.search_off : Icons.history,
              size: 36,
              color: CliphistColors.textTertiary,
            ),
            const SizedBox(height: 10),
            Text(
              hasFilter ? '没有匹配的记录' : '暂无剪贴板历史',
              style: const TextStyle(
                color: CliphistColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}