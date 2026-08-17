import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_controller.dart';
import '../src/rust/api/clipboard.dart' as api_clipboard;
import '../src/rust/api/history.dart' as api_history;
import '../src/rust/core/clipboard_engine.dart' show ClipboardItem;
import '../state/history_provider.dart';
import '../state/providers.dart';
import '../update/update_service.dart';
import '../util/image_cache.dart';
import '../util/toast.dart';
import 'category_tabs.dart';
import 'history_item.dart';
import 'status_bar.dart';
import 'theme.dart';

/// Full history screen (search + category tabs + list + empty states +
/// keyboard nav), ported from `src/lib/history-list.svelte` and redesigned
/// with a modern chrome: the search field carries the clear/settings
/// actions (the old separate toolbar + the app-level top bar were redundant
/// with the OS title bar).
///
/// Keyboard model (faithful to the Svelte version):
///  - When the search box is focused: ↑/↓ move selection, Enter copies the
///    selected row, Escape blurs the search box (does NOT hide the app).
///  - When the search box is NOT focused: digits 1-9 quick-paste the nth row.
///  - Arrow/Enter also work when the search is not focused.
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

  static const double _rowHeight = 84;
  static const double _imageRowHeight = 108;
  static const double _richRowHeight = 120;

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
    final items = _filtered;
    final zoom = ref.read(settingsProvider).zoomLevel.toDouble();
    final h = _itemExtent(items[index], zoom);
    final viewport = _scrollCtrl.position.viewportDimension;
    final offset = _scrollCtrl.offset;
    var target = 0.0;
    for (var i = 0; i < index; i++) {
      target += _itemExtent(items[i], zoom);
    }
    if (target < offset) {
      _scrollCtrl.animateTo(
        target,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
      );
    } else if (target + h > offset + viewport) {
      _scrollCtrl.animateTo(
        target + h - viewport,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
      );
    }
  }

  double _itemExtent(ClipboardItem item, double zoom) {
    final base = switch (item.contentType) {
      'image' => _imageRowHeight,
      'rich' => _richRowHeight,
      _ => _rowHeight,
    };
    // Text scales through MediaQuery. Give it corresponding vertical room so
    // 150–200% zoom never overflows fixed list extents.
    return base + (zoom - 1).clamp(0, 1).toDouble() * 50;
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
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: CliphistColors.danger,
            ),
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
    final historyCount = ref.watch(historyProvider).length;
    final zoom = ref
        .watch(settingsProvider.select((s) => s.zoomLevel))
        .toDouble();
    final update = ref.watch(updateStateProvider);

    return Focus(
      focusNode: _viewFocus,
      autofocus: true,
      child: Container(
        color: CliphistColors.bgBase,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _HeroHeader(
              count: historyCount,
              onClearHistory: _clearAll,
              onSettings: () =>
                  ref.read(settingsOpenProvider.notifier).state = true,
            ),
            _SearchBar(
              controller: _searchCtrl,
              focusNode: _searchFocus,
              value: query,
              onChanged: _onSearchQueryChanged,
              onClear: () {
                _searchCtrl.clear();
                _onSearchQueryChanged('');
              },
            ),
            if (update.hasUpdate) _UpdateBanner(update: update),
            CategoryTabs(current: category, onChanged: _onCategoryChanged),
            Expanded(
              child: filtered.isEmpty
                  ? _EmptyState(query: query, category: category)
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                      itemCount: filtered.length,
                      itemExtentBuilder: (i, _) =>
                          _itemExtent(filtered[i], zoom),
                      itemBuilder: (ctx, i) => HistoryItem(
                        key: ValueKey(filtered[i].id),
                        item: filtered[i],
                        index: i + 1,
                        selected: i == selected,
                        onTap: () =>
                            ref.read(selectedIndexProvider.notifier).state = i,
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
      ),
    );
  }
}

class _HeroHeader extends StatelessWidget {
  const _HeroHeader({
    required this.count,
    required this.onClearHistory,
    required this.onSettings,
  });

  final int count;
  final VoidCallback onClearHistory;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      decoration: const BoxDecoration(gradient: CliphistColors.brandGradient),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(13),
              boxShadow: const [
                BoxShadow(color: Color(0x24000000), blurRadius: 12),
              ],
            ),
            child: Image.asset('assets/icon/app.png'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '剪贴板',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$count 条历史记录 · 实时同步',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          _HeaderAction(
            icon: Icons.delete_sweep_outlined,
            tooltip: '清空历史',
            onTap: onClearHistory,
          ),
          _HeaderAction(
            icon: Icons.tune_rounded,
            tooltip: '设置',
            onTap: onSettings,
          ),
        ],
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, color: Colors.white, size: 19),
        style: IconButton.styleFrom(
          backgroundColor: Colors.white.withValues(alpha: 0.14),
          hoverColor: Colors.white.withValues(alpha: 0.22),
        ),
      ),
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({required this.update});
  final AppUpdateState update;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Material(
        color: CliphistColors.accentSoft,
        borderRadius: BorderRadius.circular(CliphistColors.radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(CliphistColors.radius),
          onTap: ClipHistController.instance.openLatestRelease,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                const Icon(
                  Icons.auto_awesome_rounded,
                  size: 16,
                  color: CliphistColors.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '新版本 v${update.latestVersion} 已可用',
                    style: const TextStyle(
                      color: CliphistColors.accentHover,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Text(
                  '查看',
                  style: TextStyle(
                    color: CliphistColors.accent,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 2),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 17,
                  color: CliphistColors.accent,
                ),
              ],
            ),
          ),
        ),
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
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (controller.text != value) controller.text = value;
    final hasText = value.isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      color: CliphistColors.bgBase,
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: CliphistColors.surface,
                borderRadius: BorderRadius.circular(CliphistColors.radiusLg),
                border: Border.all(color: CliphistColors.border),
                boxShadow: CliphistColors.cardShadow,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const Icon(
                    Icons.search_rounded,
                    size: 17,
                    color: CliphistColors.textMuted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      onChanged: onChanged,
                      style: const TextStyle(
                        color: CliphistColors.textPrimary,
                        fontSize: 13,
                        height: 1.3,
                      ),
                      cursorColor: CliphistColors.accent,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '搜索剪贴板历史…',
                        hintStyle: const TextStyle(
                          color: CliphistColors.textMuted,
                          fontSize: 13,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 9),
                        suffixIcon: hasText
                            ? IconButton(
                                visualDensity: VisualDensity.compact,
                                iconSize: 16,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 28,
                                  minHeight: 28,
                                ),
                                icon: const Icon(
                                  Icons.close_rounded,
                                  color: CliphistColors.textMuted,
                                ),
                                onPressed: onClear,
                              )
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
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
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasFilter ? Icons.search_off_rounded : Icons.history_rounded,
              size: 40,
              color: CliphistColors.textMuted,
            ),
            const SizedBox(height: 12),
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
