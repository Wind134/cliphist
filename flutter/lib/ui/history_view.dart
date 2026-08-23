import 'dart:async';

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
/// keyboard navigation). The search field also carries the clear/settings
/// actions so the layout stays compact alongside the OS title bar.
///
/// Keyboard model:
///  - When the search box is focused: ↑/↓ move selection, Enter copies the
///    selected row, Escape blurs the search box (does NOT hide the app).
///  - When the search box is NOT focused: digits 1-9 quick-paste the nth row.
///  - Arrow/Enter also work when the search is not focused.
class HistoryView extends ConsumerStatefulWidget {
  const HistoryView({super.key, this.onQuickPaste});

  final ValueChanged<BigInt>? onQuickPaste;

  @override
  ConsumerState<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends ConsumerState<HistoryView> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _viewFocus = FocusNode(debugLabel: 'history-view');
  final FocusNode _searchFocus = FocusNode(debugLabel: 'history-search');
  bool _quickPastePending = false;

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
    _viewFocus.requestFocus();
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
    final quickPasteIndex = quickPasteIndexForKey(key);
    if (quickPasteIndex != null) return _quickPaste(quickPasteIndex);
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
    if (_quickPastePending) return KeyEventResult.handled;
    final item = items[n - 1];
    _quickPastePending = true;
    _selectIndex(n - 1);
    unawaited(_dispatchQuickPaste(item.id));
    return KeyEventResult.handled;
  }

  Future<void> _dispatchQuickPaste(BigInt id) async {
    // Leave enough time for the number-key release and the selection bounce to
    // render before the native window is hidden. Hiding on KeyDown could send
    // the corresponding KeyUp to the target application and made the shortcut
    // feel intermittent on Windows.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    try {
      final override = widget.onQuickPaste;
      if (override != null) {
        override(id);
      } else {
        await ClipHistController.instance.quickPaste(id);
      }
    } finally {
      if (mounted) _quickPastePending = false;
    }
  }

  void _selectIndex(int index) {
    _viewFocus.requestFocus();
    ref.read(selectedIndexProvider.notifier).state = index;
    _ensureVisible(index);
  }

  void _moveSelection(int delta) {
    final items = _filtered;
    if (items.isEmpty) return;
    int cur = ref.read(selectedIndexProvider);
    if (cur < 0) {
      cur = delta > 0 ? -1 : 0;
    }
    int next = (cur + delta).clamp(0, items.length - 1);
    _selectIndex(next);
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
      unawaited(
        _scrollCtrl.animateTo(
          target,
          duration: const Duration(milliseconds: 80),
          curve: Curves.easeOut,
        ),
      );
    } else if (target + h > offset + viewport) {
      unawaited(
        _scrollCtrl.animateTo(
          target + h - viewport,
          duration: const Duration(milliseconds: 80),
          curve: Curves.easeOut,
        ),
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
    unawaited(_copyItem(items[idx], hideAfter: true));
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
    try {
      // Rust persists first and emits a full replacement snapshot. Avoid an
      // optimistic rollback: restoring an old local list could erase captures
      // that arrived while the delete request was in flight.
      await api_history.deleteItem(id: item.id);
      evictImage(item.id);
      ref.read(selectedIndexProvider.notifier).state = -1;
      showToast(_container, '已删除');
    } catch (e) {
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
    ref.listen<int>(windowWakeGenerationProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ref.read(settingsOpenProvider)) return;
        _viewFocus.requestFocus();
      });
    });
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
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      itemCount: filtered.length,
                      itemExtentBuilder: (i, _) =>
                          _itemExtent(filtered[i], zoom),
                      itemBuilder: (ctx, i) => HistoryItem(
                        key: ValueKey(filtered[i].id),
                        item: filtered[i],
                        index: i + 1,
                        selected: i == selected,
                        onTap: () => _selectIndex(i),
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
      constraints: const BoxConstraints(minHeight: 62),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: const BoxDecoration(
        color: CliphistColors.surface,
        border: Border(bottom: BorderSide(color: CliphistColors.borderSubtle)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: CliphistColors.accentSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Image.asset('assets/icon/app.png'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ClipHist',
                  style: TextStyle(
                    color: CliphistColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$count 条剪贴板记录',
                  style: const TextStyle(
                    color: CliphistColors.textMuted,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          _HeaderIconAction(
            icon: Icons.delete_sweep_outlined,
            tooltip: '清空历史',
            onTap: onClearHistory,
          ),
          const SizedBox(width: 8),
          _SettingsAction(onTap: onSettings),
        ],
      ),
    );
  }
}

class _HeaderIconAction extends StatelessWidget {
  const _HeaderIconAction({
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
      child: SizedBox.square(
        dimension: 32,
        child: IconButton(
          onPressed: onTap,
          icon: Icon(icon, color: CliphistColors.textSecondary, size: 17),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
          style: IconButton.styleFrom(
            backgroundColor: CliphistColors.surfaceSubtle,
            hoverColor: CliphistColors.hover,
            side: const BorderSide(color: CliphistColors.borderSubtle),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
    );
  }
}

class _SettingsAction extends StatelessWidget {
  const _SettingsAction({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.sizeOf(context).width < 380 ||
        MediaQuery.textScalerOf(context).scale(1) > 1.4;
    if (compact) {
      return _HeaderIconAction(
        icon: Icons.settings_outlined,
        tooltip: '设置',
        onTap: onTap,
      );
    }
    return Tooltip(
      message: '设置',
      child: SizedBox(
        height: 32,
        child: TextButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.settings_outlined, size: 16),
          label: const Text('设置'),
          style: TextButton.styleFrom(
            foregroundColor: CliphistColors.accent,
            backgroundColor: CliphistColors.accentSoft,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            side: BorderSide(
              color: CliphistColors.accent.withValues(alpha: 0.18),
            ),
          ),
        ),
      ),
    );
  }
}

int? quickPasteIndexForKey(LogicalKeyboardKey key) {
  final keys = <LogicalKeyboardKey, int>{
    LogicalKeyboardKey.digit1: 1,
    LogicalKeyboardKey.digit2: 2,
    LogicalKeyboardKey.digit3: 3,
    LogicalKeyboardKey.digit4: 4,
    LogicalKeyboardKey.digit5: 5,
    LogicalKeyboardKey.digit6: 6,
    LogicalKeyboardKey.digit7: 7,
    LogicalKeyboardKey.digit8: 8,
    LogicalKeyboardKey.digit9: 9,
    LogicalKeyboardKey.numpad1: 1,
    LogicalKeyboardKey.numpad2: 2,
    LogicalKeyboardKey.numpad3: 3,
    LogicalKeyboardKey.numpad4: 4,
    LogicalKeyboardKey.numpad5: 5,
    LogicalKeyboardKey.numpad6: 6,
    LogicalKeyboardKey.numpad7: 7,
    LogicalKeyboardKey.numpad8: 8,
    LogicalKeyboardKey.numpad9: 9,
  };
  return keys[key];
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
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      color: CliphistColors.surface,
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: CliphistColors.surface,
                borderRadius: BorderRadius.circular(CliphistColors.radiusLg),
                border: Border.all(color: CliphistColors.border),
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
