import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';

import '../src/rust/core/clipboard_engine.dart' show ClipboardItem;
import '../util/image_cache.dart';
import 'theme.dart';

/// One history row. Modern layout:
///   `[index] · [preview line(s)] … [hover actions]`
///   `[meta: timestamp · count]`
/// with a leading type dot, a 3px accent rail on the selected row, and a soft
/// hover wash. Type is conveyed by the dot color (kept calm — the old colored
/// chip + colored rail competed with the text). Image rows show a thumbnail
/// on the left.
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

  /// 1-based display index (1-9 quick-paste hint); rows past 9 show no badge.
  final int index;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  State<HistoryItem> createState() => _HistoryItemState();
}

class _HistoryItemState extends State<HistoryItem>
    with SingleTickerProviderStateMixin {
  bool _hovered = false;
  late final AnimationController _selectionBounce;
  late final Animation<double> _selectionScale;

  @override
  void initState() {
    super.initState();
    _selectionBounce = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _selectionScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1,
          end: 1.014,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 42,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.014,
          end: 0.997,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 30,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.997,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 28,
      ),
    ]).animate(_selectionBounce);
  }

  @override
  void didUpdateWidget(covariant HistoryItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected && !oldWidget.selected) {
      unawaited(_selectionBounce.forward(from: 0));
    } else if (!widget.selected && oldWidget.selected) {
      _selectionBounce
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _selectionBounce.dispose();
    super.dispose();
  }

  ClipType get _type => ClipType.of(widget.item.contentType) ?? ClipType.all;

  Color get _rowBg {
    if (widget.selected) return CliphistColors.selected;
    if (_hovered) return CliphistColors.hover;
    return CliphistColors.surface;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isImage = item.contentType == 'image';
    return AnimatedBuilder(
      animation: _selectionScale,
      builder: (context, child) => Transform.scale(
        key: ValueKey('history-item-motion-${item.id}'),
        scale: _selectionScale.value,
        alignment: Alignment.center,
        child: child,
      ),
      child: Semantics(
        selected: widget.selected,
        button: true,
        onTap: widget.onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Listener(
            // Select immediately on pointer down. Waiting for GestureDetector's
            // double-tap arbitration made row selection feel sluggish.
            onPointerDown: (_) => widget.onTap(),
            child: GestureDetector(
              key: ValueKey('history-item-tap-${item.id}'),
              onDoubleTap: widget.onDoubleTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: _rowBg,
                  borderRadius: BorderRadius.circular(CliphistColors.radiusLg),
                  border: Border.all(
                    color: widget.selected
                        ? CliphistColors.accent.withValues(alpha: 0.42)
                        : CliphistColors.borderSubtle,
                  ),
                  boxShadow: widget.selected
                      ? [
                          BoxShadow(
                            color: CliphistColors.accent.withValues(
                              alpha: 0.10,
                            ),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ]
                      : null,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Keep the rail in the layout while animating its color and
                    // height so selection never shifts the row contents.
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeOutCubic,
                      width: 3,
                      height: widget.selected ? 36 : 18,
                      decoration: BoxDecoration(
                        color: widget.selected
                            ? CliphistColors.accent
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 9),
                    _Index(index: widget.index, selected: widget.selected),
                    const SizedBox(width: 10),
                    if (isImage) ...[
                      _ImagePreview(id: item.id),
                      const SizedBox(width: 12),
                    ] else
                      _TypeBadge(type: _type),
                    const SizedBox(width: 10),
                    Expanded(child: _body(item, isImage)),
                    SizedBox(
                      width: 54,
                      child: AnimatedOpacity(
                        opacity: _hovered || widget.selected ? 1 : 0,
                        duration: const Duration(milliseconds: 120),
                        child: IgnorePointer(
                          ignoring: !_hovered && !widget.selected,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
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
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(ClipboardItem item, bool isImage) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _preview(item),
        const SizedBox(height: 3),
        Text(
          _meta(item),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: CliphistColors.textMuted,
            fontSize: 11,
            height: 1.25,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _preview(ClipboardItem item) {
    if (item.contentType == 'rich' && item.htmlContent != null) {
      // HTML is sanitized at add-time in Rust (ammonia); the Dart widget is a
      // second line of defense. Constrain height so the row stays compact.
      return ClipRect(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 72),
          child: HtmlWidget(
            item.htmlContent!,
            textStyle: const TextStyle(
              color: CliphistColors.textPrimary,
              fontSize: 13,
              height: 1.35,
            ),
            renderMode: RenderMode.column,
          ),
        ),
      );
    }
    final preview = item.preview.isNotEmpty ? item.preview : item.content;
    return Text(
      preview,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: CliphistColors.textPrimary,
        fontSize: 13,
        height: 1.35,
      ),
    );
  }

  String _meta(ClipboardItem item) {
    final time = item.timestamp;
    if (item.contentType == 'image') {
      final w = item.imageWidth ?? 0;
      final h = item.imageHeight ?? 0;
      final dim = w > 0 && h > 0 ? '$w × $h px' : '图片';
      return '$time · $dim';
    }
    final count = item.charCount.toInt();
    return '$time · $count 字符';
  }
}

class _Index extends StatelessWidget {
  const _Index({required this.index, required this.selected});
  final int index;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    if (index < 1 || index > 9) return const SizedBox(width: 24);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? CliphistColors.accent : CliphistColors.surface,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: selected ? CliphistColors.accent : CliphistColors.border,
        ),
      ),
      child: Text(
        '$index',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: selected ? Colors.white : CliphistColors.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          height: 1.2,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.type});
  final ClipType type;

  IconData get _icon => switch (type.key) {
    'link' => Icons.link_rounded,
    'rich' => Icons.format_color_text_rounded,
    'short' => Icons.short_text_rounded,
    _ => Icons.notes_rounded,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: type.color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: type.color.withValues(alpha: 0.18)),
      ),
      child: Icon(_icon, size: 16, color: type.color),
    );
  }
}

class _ImagePreview extends StatefulWidget {
  const _ImagePreview({required this.id});
  final BigInt id;

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
    unawaited(_load());
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
      return Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: CliphistColors.surfaceSubtle,
          borderRadius: BorderRadius.circular(CliphistColors.radius),
        ),
        child: const Icon(
          Icons.broken_image_outlined,
          size: 20,
          color: CliphistColors.textMuted,
        ),
      );
    }
    if (!_loaded) {
      return Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: CliphistColors.surfaceSubtle,
          borderRadius: BorderRadius.circular(CliphistColors.radius),
        ),
        child: const Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: CliphistColors.textMuted,
            ),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(CliphistColors.radius),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 72, maxWidth: 96),
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
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 16, color: CliphistColors.textSecondary),
        ),
      ),
    );
  }
}
