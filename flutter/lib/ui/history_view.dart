import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_controller.dart';
import '../src/rust/api/clipboard.dart' as api_clipboard;
import '../src/rust/api/history.dart' as api_history;
import '../src/rust/core/clipboard_engine.dart' show ClipboardItem;
import '../state/history_provider.dart';
import '../state/providers.dart';
import '../update/update_service.dart';
import '../util/image_cache.dart';
import '../util/relative_time.dart';
import '../util/toast.dart';
import 'category_tabs.dart';
import 'chrome.dart';
import 'history_item.dart';
import 'kbd.dart';
import 'status_bar.dart';
import 'theme.dart';

/// Full history screen. Keyboard:
///  - Search focused: ↑/↓ select, Enter copies, Esc clears then blurs.
///  - List focused: 1–9 quick-paste, Space expands, Del deletes.
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
  bool _searchFocused = false;
  BigInt? _expandedId;

  @override
  void initState() {
    super.initState();
    _searchFocus.onKeyEvent = _onSearchKeyEvent;
    _viewFocus.onKeyEvent = _onViewKeyEvent;
    _searchFocus.addListener(() {
      if (mounted) setState(() => _searchFocused = _searchFocus.hasFocus);
    });
    _scrollCtrl.addListener(_onScroll);
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

  void _onScroll() {
    // Close any image peek by rebuilding; tiles hide on pointer exit too.
  }

  void _onSearchQueryChanged(String q) {
    ref.read(searchQueryProvider.notifier).state = q;
    ref.read(selectedIndexProvider.notifier).state = -1;
    setState(() => _expandedId = null);
  }

  void _onCategoryChanged(String cat) {
    ref.read(currentCategoryProvider.notifier).state = cat;
    ref.read(selectedIndexProvider.notifier).state = -1;
    setState(() => _expandedId = null);
    _viewFocus.requestFocus();
  }

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
      if (_searchCtrl.text.isNotEmpty) {
        _searchCtrl.clear();
        _onSearchQueryChanged('');
      } else {
        _viewFocus.requestFocus();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onViewKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final mods = HardwareKeyboard.instance.logicalKeysPressed;
    final ctrl =
        mods.contains(LogicalKeyboardKey.controlLeft) ||
        mods.contains(LogicalKeyboardKey.controlRight) ||
        mods.contains(LogicalKeyboardKey.metaLeft) ||
        mods.contains(LogicalKeyboardKey.metaRight);

    if (ctrl && key == LogicalKeyboardKey.keyF) {
      _searchFocus.requestFocus();
      _searchCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _searchCtrl.text.length,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.slash && !ctrl) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }

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
    if (key == LogicalKeyboardKey.space) {
      _toggleExpandSelected();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      _deleteSelected();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

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
    final next = (cur + delta).clamp(0, items.length - 1);
    _selectIndex(next);
  }

  void _ensureVisible(int index) {
    if (!_scrollCtrl.hasClients) return;
    final compact = ref.read(settingsProvider).listDensity == 'compact';
    final h = compact ? Sizes.rowCompact : Sizes.row;
    final target = index * (h + 18); // rough: group headers
    final offset = _scrollCtrl.offset;
    final viewport = _scrollCtrl.position.viewportDimension;
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

  void _handleEnter() {
    final items = _filtered;
    final idx = ref.read(selectedIndexProvider);
    if (idx < 0 || idx >= items.length) return;
    unawaited(_copyItem(items[idx], hideAfter: true));
  }

  void _toggleExpandSelected() {
    final items = _filtered;
    final idx = ref.read(selectedIndexProvider);
    if (idx < 0 || idx >= items.length) return;
    final id = items[idx].id;
    setState(() => _expandedId = _expandedId == id ? null : id);
  }

  void _deleteSelected() {
    final items = _filtered;
    final idx = ref.read(selectedIndexProvider);
    if (idx < 0 || idx >= items.length) return;
    unawaited(_deleteItem(items[idx]));
  }

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
      await api_history.deleteItem(id: item.id);
      evictImage(item.id);
      if (_expandedId == item.id) setState(() => _expandedId = null);
      ref.read(selectedIndexProvider.notifier).state = -1;
      showToast(_container, '已删除');
    } catch (e) {
      showToast(_container, '删除失败: $e');
    }
  }

  Future<void> _clearAll() async {
    final c = context.c;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '清空全部记录？',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: c.text,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '此操作不可撤销。',
                  style: TextStyle(fontSize: 12.5, color: c.text2),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: c.danger,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 30),
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('清空'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      await api_history.clearHistory();
      showToast(_container, '已清空');
    } catch (e) {
      showToast(_container, '清空失败: $e');
    }
  }

  Map<String, int> _countsFor(List<ClipboardItem> hist, String query) {
    var items = hist;
    if (query.isNotEmpty) {
      final q = query.toLowerCase();
      items = items.where((i) => i.content.toLowerCase().contains(q)).toList();
    }
    final map = <String, int>{};
    for (final i in items) {
      map[i.contentType] = (map[i.contentType] ?? 0) + 1;
    }
    return map;
  }

  List<_Group> _groups(List<ClipboardItem> items) {
    final groups = <_Group>[];
    for (var i = 0; i < items.length; i++) {
      final label = groupLabel(items[i].timestamp);
      if (groups.isEmpty || groups.last.label != label) {
        groups.add(_Group(label, []));
      }
      groups.last.items.add((i, items[i]));
    }
    return groups;
  }

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
    final history = ref.watch(historyProvider);
    final settings = ref.watch(settingsProvider);
    final update = ref.watch(updateStateProvider);
    final compact = settings.listDensity == 'compact';
    final groups = _groups(filtered);
    final counts = _countsFor(history, query);
    final c = context.c;

    return Focus(
      focusNode: _viewFocus,
      autofocus: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppTitleBar(
            leading: Row(
              children: [
                Flexible(
                  child: Text(
                    '剪贴板历史',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 18 / 13,
                      fontWeight: FontWeight.w600,
                      color: c.text,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CountPill(history.length),
              ],
            ),
            actions: [
              IconBtn(
                icon: LucideIcons.trash2,
                tooltip: '清空全部记录',
                danger: true,
                onTap: _clearAll,
              ),
              IconBtn(
                key: const ValueKey('open-settings'),
                icon: LucideIcons.settings,
                tooltip: isMac ? '设置 (⌘,)' : '设置 (Ctrl+,)',
                onTap: () =>
                    ref.read(settingsOpenProvider.notifier).state = true,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              children: [
                _SearchField(
                  controller: _searchCtrl,
                  focusNode: _searchFocus,
                  focused: _searchFocused,
                  value: query,
                  onChanged: _onSearchQueryChanged,
                  onClear: () {
                    _searchCtrl.clear();
                    _onSearchQueryChanged('');
                  },
                ),
                const SizedBox(height: 8),
                CategoryTabs(
                  current: category,
                  onChanged: _onCategoryChanged,
                  counts: counts,
                ),
              ],
            ),
          ),
          if (update.hasUpdate) _UpdateBanner(update: update),
          Expanded(
            child: filtered.isEmpty
                ? _EmptyState(query: query, category: category)
                : Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                    child: CustomScrollView(
                      controller: _scrollCtrl,
                      slivers: [
                        for (final g in groups) ...[
                          SliverPersistentHeader(
                            pinned: true,
                            delegate: _GroupHeaderDelegate(
                              g.label,
                              MediaQuery.textScalerOf(context).scale(1),
                            ),
                          ),
                          SliverList.builder(
                            itemCount: g.items.length,
                            itemBuilder: (ctx, i) {
                              final (idx, item) = g.items[i];
                              return HistoryItem(
                                key: ValueKey(item.id),
                                item: item,
                                index: idx + 1,
                                selected: idx == selected,
                                expanded: _expandedId == item.id,
                                compact: compact,
                                query: query,
                                showDivider: i > 0,
                                onTap: () => _selectIndex(idx),
                                onDoubleTap: () =>
                                    _copyItem(item, hideAfter: true),
                                onShowDetails: () => setState(
                                  () => _expandedId = _expandedId == item.id
                                      ? null
                                      : item.id,
                                ),
                                onCopy: () => _copyItem(item),
                                onDelete: () => _deleteItem(item),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
          StatusBar(
            helperConnected: helper,
            gameMode: settings.gameMode,
            doubleTapKey: settings.doubleTapKey,
          ),
        ],
      ),
    );
  }
}

class _Group {
  _Group(this.label, this.items);
  final String label;
  final List<(int, ClipboardItem)> items;
}

class _GroupHeaderDelegate extends SliverPersistentHeaderDelegate {
  _GroupHeaderDelegate(this.label, this.textScale);
  final String label;
  final double textScale;

  // Padding is unscaled; the 11/14 overline is scaled by MediaQuery.
  double get _extent => 12 + 6 + 14 * textScale;

  @override
  double get minExtent => _extent;
  @override
  double get maxExtent => _extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final c = context.c;
    return ColoredBox(
      color: c.bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(9, 12, 9, 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              height: 14 / 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: c.text3,
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _GroupHeaderDelegate old) =>
      old.label != label || old.textScale != textScale;
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
    final c = context.c;
    final downloading = update.phase == UpdatePhase.downloading;
    final applying = update.phase == UpdatePhase.applying;
    final busy = downloading || applying;
    final percent = (update.downloadProgress * 100).round();
    final title = downloading
        ? '正在下载 v${update.latestVersion}  $percent%'
        : applying
        ? '正在安装 v${update.latestVersion}…'
        : '新版本 v${update.latestVersion} 已可用';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: busy
              ? null
              : ClipHistController.instance.downloadAndInstallUpdate,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(LucideIcons.sparkles, size: 14, color: c.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: c.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (!busy)
                  Text(
                    '更新',
                    style: TextStyle(
                      color: c.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.focused,
    required this.value,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool focused;
  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (controller.text != value) controller.text = value;
    final c = context.c;
    final hasText = value.isNotEmpty;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      height: Sizes.search,
      decoration: BoxDecoration(
        color: focused ? c.bg : c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: focused ? c.selBorder : Colors.transparent),
        boxShadow: focused
            ? [BoxShadow(color: c.accentSoft, spreadRadius: 3, blurRadius: 0)]
            : null,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Icon(LucideIcons.search, size: 16, color: c.text3),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              style: TextStyle(color: c.text, fontSize: 13, height: 18 / 13),
              cursorColor: c.accent,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索剪贴板历史…',
                hintStyle: TextStyle(color: c.text3, fontSize: 13),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
              ),
            ),
          ),
          if (hasText)
            GestureDetector(
              onTap: onClear,
              child: Icon(LucideIcons.x, size: 14, color: c.text3),
            )
          else
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Kbd(isMac ? '⌘F' : 'Ctrl F'),
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
    final c = context.c;
    final searching = query.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              searching ? LucideIcons.search : LucideIcons.clipboard,
              size: 28,
              color: c.text3.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 10),
            Text(
              searching
                  ? '没有找到包含「$query」的记录'
                  : category != 'all'
                  ? '没有匹配的记录'
                  : '这里还没有记录',
              textAlign: TextAlign.center,
              style: TextStyle(color: c.text3, fontSize: 12.5),
            ),
            if (!searching && category == 'all') ...[
              const SizedBox(height: 4),
              Text('复制点什么试试吧', style: TextStyle(color: c.text4, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}
