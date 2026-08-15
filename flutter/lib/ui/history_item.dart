import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../src/rust/core/clipboard_engine.dart' show ClipboardItem;
import '../util/image_cache.dart';
import 'theme.dart';

/// One history row, ported from `src/lib/history-item.svelte`.
///
/// Layout: `[index badge] [type chip + preview] [timestamp + meta]` with copy
/// / delete buttons revealed on hover. The selected row gets an accent rail.
/// Image rows lazy-load bytes via [getImageData]; rich rows show the plain
/// text preview for now (the HTML widget lands in M6).
class HistoryItem extends StatefulWidget {
  const HistoryItem({
    super.key,
    required this.item,
    required this.index,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
    required this.onCopy,
    required this.onDelete,
  });

  final ClipboardItem item;
  /// 1-based display index (1-9); rows past 9 show no badge.
  final int index;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  State<HistoryItem> createState() => _HistoryItemState();
}

class _HistoryItemState extends State<HistoryItem> {
  bool _hovered = false;

  Color get _typeColor {
    switch (widget.item.contentType) {
      case 'image':
        return const Color(0xFF059669);
      case 'text':
        return const Color(0xFF107C10);
      case 'short':
        return const Color(0xFF8764B8);
      case 'link':
        return CliphistColors.accent;
      case 'rich':
        return const Color(0xFFE11D48);
      default:
        return CliphistColors.textSecondary;
    }
  }

  String get _typeLabel {
    switch (widget.item.contentType) {
      case 'image':
        return '图片';
      case 'text':
        return '文本';
      case 'short':
        return '短文本';
      case 'link':
        return '链接';
      case 'rich':
        return '富文本';
      default:
        return widget.item.contentType;
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final bg = widget.selected
        ? CliphistColors.bgActive
        : (_hovered ? CliphistColors.bgHover : CliphistColors.bgSecondary);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              left: BorderSide(
                color: widget.selected ? _typeColor : Colors.transparent,
                width: 3,
              ),
              bottom:
                  const BorderSide(color: CliphistColors.border, width: 1),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _IndexBadge(index: widget.index),
              const SizedBox(width: 8),
              Expanded(child: _body(item)),
              if (_hovered) ...[
                _IconBtn(
                  icon: Icons.content_copy,
                  tooltip: '复制',
                  onTap: widget.onCopy,
                ),
                _IconBtn(
                  icon: Icons.delete_outline,
                  tooltip: '删除',
                  onTap: widget.onDelete,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(ClipboardItem item) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: _typeColor.withOpacity(0.12),
                borderRadius:
                    BorderRadius.circular(CliphistColors.radiusSm),
              ),
              child: Text(
                _typeLabel,
                style: TextStyle(
                  color: _typeColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                item.timestamp,
                style: const TextStyle(
                  color: CliphistColors.textTertiary,
                  fontSize: 10,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _preview(item),
        const SizedBox(height: 3),
        Text(
          _meta(item),
          style: const TextStyle(
            color: CliphistColors.textTertiary,
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  Widget _preview(ClipboardItem item) {
    if (item.contentType == 'image') {
      return _ImagePreview(id: item.id, width: item.imageWidth);
    }
    // rich: plain text preview for now (M6 swaps in HtmlWidget).
    final preview = item.preview.isNotEmpty ? item.preview : item.content;
    return Text(
      preview,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: CliphistColors.textPrimary,
        fontSize: 12,
        height: 1.3,
      ),
    );
  }

  String _meta(ClipboardItem item) {
    if (item.contentType == 'image') {
      final w = item.imageWidth ?? 0;
      final h = item.imageHeight ?? 0;
      return w > 0 && h > 0 ? '$w × $h px' : '';
    }
    final count = item.charCount.toInt();
    return '$count 字符';
  }
}

class _IndexBadge extends StatelessWidget {
  const _IndexBadge({required this.index});
  final int index;

  @override
  Widget build(BuildContext context) {
    if (index < 1 || index > 9) {
      return const SizedBox(width: 18, height: 18);
    }
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: CliphistColors.bgTertiary,
        borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
      ),
      child: Text(
        '$index',
        style: const TextStyle(
          color: CliphistColors.textSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ImagePreview extends StatefulWidget {
  const _ImagePreview({required this.id, required this.width});
  final BigInt id;
  final int? width;

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  Uint8List? _bytes;
  bool _loaded = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await getImageData(widget.id);
      if (!mounted) return;
      if (b != null) {
        setState(() {
          _bytes = b;
          _loaded = true;
        });
      } else {
        setState(() => _failed = true);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image, size: 14, color: CliphistColors.textTertiary),
          SizedBox(width: 4),
          Text(
            '图片加载失败',
            style: TextStyle(color: CliphistColors.textTertiary, fontSize: 11),
          ),
        ],
      );
    }
    if (!_loaded) {
      return const SizedBox(
        height: 48,
        width: 48,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: CliphistColors.textTertiary,
            ),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 96),
        child: Image.memory(_bytes!, fit: BoxFit.contain),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
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
      child: InkWell(
        borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 15, color: CliphistColors.textSecondary),
        ),
      ),
    );
  }
}