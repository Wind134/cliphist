import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../src/rust/core/clipboard_engine.dart' show ClipboardItem;
import '../util/image_cache.dart';
import '../util/relative_time.dart';
import 'theme.dart';

IconData typeIconOf(ClipboardItem item) {
  return switch (item.contentType) {
    'image' => LucideIcons.image,
    'link' => LucideIcons.link,
    'files' => LucideIcons.file,
    'short' => LucideIcons.type,
    'rich' => LucideIcons.baseline,
    _ => looksLikeCode(item) ? LucideIcons.code : LucideIcons.alignLeft,
  };
}

bool looksLikeCode(ClipboardItem item) {
  final s = item.content;
  if (!s.contains('\n')) return false;
  return s.contains('{') ||
      s.contains('=>') ||
      s.contains('function ') ||
      s.contains('import ') ||
      s.contains('def ') ||
      s.contains('class ');
}

class HistoryItem extends StatefulWidget {
  const HistoryItem({
    super.key,
    required this.item,
    required this.index,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
    required this.onShowDetails,
    required this.onCopy,
    required this.onDelete,
    this.expanded = false,
    this.compact = false,
    this.query = '',
  });

  final ClipboardItem item;
  final int index;
  final bool selected;
  final bool expanded;
  final bool compact;
  final String query;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onShowDetails;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  State<HistoryItem> createState() => _HistoryItemState();
}

class _HistoryItemState extends State<HistoryItem> {
  bool _hovered = false;

  bool get _active => _hovered || widget.selected;
  bool get _isImage => widget.item.contentType == 'image';

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final compact = widget.compact;
    final gap = compact ? 8.0 : 10.0;
    final item = widget.item;

    final row = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerDown: (_) => widget.onTap(),
        child: GestureDetector(
          key: ValueKey('history-item-tap-${item.id}'),
          onDoubleTap: widget.onDoubleTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            constraints: BoxConstraints(
              minHeight: _isImage
                  ? (compact ? 40.0 : 60.0)
                  : (compact ? Sizes.rowCompact : Sizes.row),
            ),
            decoration: BoxDecoration(
              color: widget.selected
                  ? c.rowSel
                  : _hovered
                  ? c.hover
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: widget.selected ? c.rowSelBorder : Colors.transparent,
              ),
            ),
            child: Stack(
              alignment: Alignment.centerRight,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: compact ? 4 : 6,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: Center(
                          child: _IndexBadge(
                            index: widget.index,
                            selected: widget.selected,
                          ),
                        ),
                      ),
                      SizedBox(width: gap),
                      _Lead(item: item, compact: compact, active: _active),
                      SizedBox(width: gap),
                      Expanded(
                        child: _Texts(
                          item: item,
                          query: widget.query,
                          showMeta: !compact,
                        ),
                      ),
                      SizedBox(
                        width: Sizes.timeCol,
                        child: Opacity(
                          opacity: _active ? 0 : 1,
                          child: Text(
                            relativeTime(item.timestamp),
                            textAlign: TextAlign.right,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 11,
                              height: 18 / 11,
                              color: c.text3,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_active)
                  Positioned(
                    right: 8,
                    child: _ItemActions(
                      id: item.id,
                      expanded: widget.expanded,
                      onExpand: widget.onShowDetails,
                      onCopy: widget.onCopy,
                      onDelete: widget.onDelete,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        if (widget.expanded) _ExpandBody(item: item),
      ],
    );
  }
}

class _IndexBadge extends StatelessWidget {
  const _IndexBadge({required this.index, required this.selected});
  final int index;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (index < 1) return const SizedBox.shrink();
    if (index > 9) {
      return Container(
        width: 4,
        height: 4,
        decoration: BoxDecoration(color: c.text4, shape: BoxShape.circle),
      );
    }
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: selected ? c.borderStrong : c.border),
      ),
      child: Text(
        '$index',
        style: TextStyle(
          fontSize: 10.5,
          height: 1.1,
          fontWeight: FontWeight.w500,
          color: selected ? c.text2 : c.text3,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _Lead extends StatelessWidget {
  const _Lead({
    required this.item,
    required this.compact,
    required this.active,
  });
  final ClipboardItem item;
  final bool compact;
  final bool active;

  @override
  Widget build(BuildContext context) {
    if (item.contentType == 'image') {
      return _Thumb(id: item.id, compact: compact);
    }
    final c = context.c;
    final size = compact
        ? const Size(Sizes.leadCompactW, Sizes.leadCompactH)
        : const Size(Sizes.leadW, Sizes.leadH);
    return SizedBox.fromSize(
      size: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.leadBg,
          borderRadius: BorderRadius.circular(compact ? 4 : 6),
          border: Border.all(color: c.leadBorder),
        ),
        child: Center(
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: active ? c.accent : c.text2),
            duration: const Duration(milliseconds: 120),
            builder: (_, color, _) =>
                Icon(typeIconOf(item), size: compact ? 14 : 16, color: color),
          ),
        ),
      ),
    );
  }
}

/// In-row image so each picture row is identifiable without hovering.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.id, required this.compact});
  final BigInt id;
  final bool compact;

  static const sizeStd = Size(72, 48);
  static const sizeCompact = Size(48, 32);

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final size = compact ? sizeCompact : sizeStd;
    final radius = BorderRadius.circular(compact ? 4 : 6);
    return SizedBox.fromSize(
      size: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.leadBg,
          borderRadius: radius,
          border: Border.all(color: c.imgHairline),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: FutureBuilder<Uint8List?>(
            future: getImageData(id),
            builder: (context, snap) {
              final bytes = snap.data;
              if (bytes == null) {
                return Center(
                  child: Icon(
                    LucideIcons.image,
                    size: compact ? 14 : 16,
                    color: c.text3,
                  ),
                );
              }
              Widget img = Image.memory(
                bytes,
                fit: BoxFit.cover,
                width: size.width,
                height: size.height,
                cacheWidth: (size.width * 2).round(),
                gaplessPlayback: true,
              );
              if (dark) {
                img = ColorFiltered(
                  colorFilter: const ColorFilter.mode(
                    Color(0x24000000),
                    BlendMode.srcATop,
                  ),
                  child: img,
                );
              }
              return img;
            },
          ),
        ),
      ),
    );
  }
}

class _Texts extends StatelessWidget {
  const _Texts({
    required this.item,
    required this.query,
    required this.showMeta,
  });
  final ClipboardItem item;
  final String query;
  final bool showMeta;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final raw = item.contentType == 'files'
        ? (item.filePaths?.join('  ') ?? item.content)
        : (item.content.isNotEmpty ? item.content : item.preview);
    final body = raw.replaceAll(RegExp(r'[\t\r\n]+'), ' ').trim();
    final mono =
        item.contentType == 'link' ||
        item.contentType == 'files' ||
        looksLikeCode(item);
    final isImage = item.contentType == 'image';
    final lines = showMeta ? 2 : 1;
    final showBody = !isImage || body.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showBody)
          Text.rich(
            highlightSpans(
              body,
              query,
              TextStyle(
                fontSize: mono ? 12 : 13,
                height: 18 / (mono ? 12 : 13),
                color: c.text,
                fontFamily: mono ? monoFamily : null,
                fontFamilyFallback: mono ? monoFallback : null,
              ),
              c.warn.withValues(alpha: 0.35),
            ),
            maxLines: isImage ? 1 : lines,
            overflow: TextOverflow.ellipsis,
          ),
        if (showMeta) ...[
          const SizedBox(height: 1),
          Text.rich(
            TextSpan(
              style: TextStyle(
                fontSize: 11,
                height: 15 / 11,
                color: c.text3,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              children: _metaSpans(item, c),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

List<InlineSpan> _metaSpans(ClipboardItem item, AppColors c) {
  final type = ClipType.of(item.contentType)?.label ?? '文本';
  final parts = <String>[type];
  if (item.contentType == 'image') {
    final w = item.imageWidth ?? 0;
    final h = item.imageHeight ?? 0;
    if (w > 0 && h > 0) parts.add('$w × $h px');
  } else if (item.contentType == 'files') {
    final n = item.filePaths?.length ?? item.charCount.toInt();
    parts.add('$n 个文件');
  } else if (item.contentType == 'link') {
    try {
      parts.add(Uri.parse(item.content).host);
    } catch (_) {}
  } else {
    parts.add('${item.charCount.toInt()} 字');
  }
  final spans = <InlineSpan>[];
  for (var i = 0; i < parts.length; i++) {
    if (i > 0) {
      spans.add(
        TextSpan(
          text: ' · ',
          style: TextStyle(color: c.text4),
        ),
      );
    }
    spans.add(TextSpan(text: parts[i]));
  }
  return spans;
}

TextSpan highlightSpans(
  String text,
  String query,
  TextStyle style,
  Color mark,
) {
  if (query.isEmpty) return TextSpan(text: text, style: style);
  final lower = text.toLowerCase();
  final q = query.toLowerCase();
  final children = <InlineSpan>[];
  var start = 0;
  while (true) {
    final i = lower.indexOf(q, start);
    if (i < 0) {
      if (start < text.length) {
        children.add(TextSpan(text: text.substring(start), style: style));
      }
      break;
    }
    if (i > start) {
      children.add(TextSpan(text: text.substring(start, i), style: style));
    }
    children.add(
      TextSpan(
        text: text.substring(i, i + q.length),
        style: style.copyWith(backgroundColor: mark),
      ),
    );
    start = i + q.length;
  }
  return TextSpan(children: children, style: style);
}

class _ItemActions extends StatelessWidget {
  const _ItemActions({
    required this.id,
    required this.expanded,
    required this.onExpand,
    required this.onCopy,
    required this.onDelete,
  });
  final BigInt id;
  final bool expanded;
  final VoidCallback onExpand;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children:
          [
                _ActionBtn(
                  buttonKey: ValueKey('history-item-details-$id'),
                  icon: expanded
                      ? LucideIcons.chevronUp
                      : LucideIcons.chevronDown,
                  tooltip: '展开 (Space)',
                  onTap: onExpand,
                ),
                _ActionBtn(
                  icon: LucideIcons.copy,
                  tooltip: '复制 (Enter)',
                  onTap: onCopy,
                ),
                _ActionBtn(
                  icon: LucideIcons.trash2,
                  tooltip: '删除 (Del)',
                  danger: true,
                  onTap: onDelete,
                ),
              ]
              .map(
                (w) => Container(
                  margin: const EdgeInsets.only(left: 2),
                  decoration: BoxDecoration(
                    color: c.bg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: c.border),
                  ),
                  child: w,
                ),
              )
              .toList(),
    );
  }
}

class _ActionBtn extends StatefulWidget {
  const _ActionBtn({
    this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });
  final Key? buttonKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_ActionBtn> createState() => _ActionBtnState();
}

class _ActionBtnState extends State<_ActionBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final fg = widget.danger && _hover
        ? c.danger
        : _hover
        ? c.text
        : c.text2;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          key: widget.buttonKey,
          onTap: widget.onTap,
          child: SizedBox(
            width: 26,
            height: 26,
            child: Icon(widget.icon, size: 14, color: fg),
          ),
        ),
      ),
    );
  }
}

class _ExpandBody extends StatelessWidget {
  const _ExpandBody({required this.item});
  final ClipboardItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(37, 2, 9, 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.bgSub,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: item.contentType == 'image'
                ? _ExpandImage(item: item, dark: dark)
                : SelectionArea(
                    child: Text(
                      item.contentType == 'files'
                          ? (item.filePaths?.join('\n') ?? item.content)
                          : item.content,
                      key: ValueKey('history-item-full-content-${item.id}'),
                      style: TextStyle(
                        fontSize:
                            item.contentType == 'link' || looksLikeCode(item)
                            ? 12
                            : 12.5,
                        height: 1.6,
                        color: c.text,
                        fontFamily:
                            item.contentType == 'files' ||
                                looksLikeCode(item) ||
                                item.contentType == 'link'
                            ? monoFamily
                            : null,
                        fontFamilyFallback: monoFallback,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _ExpandImage extends StatelessWidget {
  const _ExpandImage({required this.item, required this.dark});
  final ClipboardItem item;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final w = item.imageWidth ?? 0;
    final h = item.imageHeight ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FutureBuilder<Uint8List?>(
          future: getImageData(item.id),
          builder: (context, snap) {
            final bytes = snap.data;
            if (bytes == null) {
              return const SizedBox(
                height: 80,
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            Widget img = ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 150),
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            );
            if (dark) {
              img = ColorFiltered(
                colorFilter: const ColorFilter.mode(
                  Color(0x24000000),
                  BlendMode.srcATop,
                ),
                child: img,
              );
            }
            return DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: c.imgHairline),
                borderRadius: BorderRadius.circular(6),
              ),
              child: img,
            );
          },
        ),
        const SizedBox(height: 6),
        Text(
          [
            if (w > 0 && h > 0) '$w × $h px',
            relativeTime(item.timestamp),
          ].join(' · '),
          style: TextStyle(fontSize: 11, color: c.text3),
        ),
      ],
    );
  }
}
