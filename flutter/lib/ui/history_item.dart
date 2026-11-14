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

String displayTextOf(ClipboardItem item) {
  if (item.contentType == 'files') {
    return filePathsOf(item).join('\n');
  }
  return item.content.isNotEmpty ? item.content : item.preview;
}

/// File paths of a `files` item, falling back to newline-separated content.
List<String> filePathsOf(ClipboardItem item) {
  final paths = item.filePaths;
  if (paths != null && paths.isNotEmpty) return paths;
  return item.content
      .split(RegExp(r'\r?\n'))
      .where((s) => s.trim().isNotEmpty)
      .toList();
}

String typeLabelOf(ClipboardItem item) =>
    looksLikeCode(item) ? '代码' : (ClipType.of(item.contentType)?.label ?? '文本');

String _metaLine(ClipboardItem item) {
  final parts = <String>[typeLabelOf(item)];
  if (item.contentType == 'image') {
    // source app is not available; keep type only
  } else if (item.contentType == 'files') {
    final n = item.filePaths?.length ?? item.charCount.toInt();
    parts.add('$n 个文件');
  } else if (item.contentType == 'link') {
    try {
      final host = Uri.parse(item.content).host;
      if (host.isNotEmpty) parts.add(host);
    } catch (_) {}
  } else {
    parts.add('${item.charCount.toInt()} 字');
    final lines = '\n'.allMatches(item.content).length + 1;
    if (lines > 1) parts.add('$lines 行');
  }
  return parts.join(' · ');
}

String _imageName(ClipboardItem item) {
  // Rust stores a generated "图片 WxH" preview; the size has its own line.
  final name = item.preview.trim();
  return (name.isEmpty || name.startsWith('图片')) ? '图片' : name;
}

String? _imageSize(ClipboardItem item) {
  final w = item.imageWidth ?? 0;
  final h = item.imageHeight ?? 0;
  return (w > 0 && h > 0) ? '$w × $h px' : null;
}

class HistoryItem extends StatefulWidget {
  const HistoryItem({
    super.key,
    required this.item,
    required this.index,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
    required this.onPreview,
    required this.onCopy,
    required this.onDelete,
    this.compact = false,
    this.query = '',
    this.showDivider = false,
  });

  final ClipboardItem item;
  final int index;
  final bool selected;
  final bool compact;
  final String query;
  final bool showDivider;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onPreview;
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
    final gap = compact ? 6.0 : 8.0;
    final padY = compact ? 8.0 : 10.0;
    final lead = compact ? Sizes.leadCompactH : Sizes.leadH;
    final item = widget.item;
    final maxLines = compact ? 4 : 8;
    const metaStyle = TextStyle(
      fontSize: 11,
      height: 1.2,
      fontFeatures: [FontFeature.tabularFigures()],
    );

    return Column(
      children: [
        if (widget.showDivider && !_active)
          Divider(height: 1, indent: 8, endIndent: 8, color: c.border),
        MouseRegion(
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
                decoration: BoxDecoration(
                  color: widget.selected
                      ? c.rowSel
                      : _hovered
                      ? c.hover
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: widget.selected
                        ? c.rowSelBorder
                        : Colors.transparent,
                  ),
                ),
                child: Stack(
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: padY,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            height: context.sp(lead),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                _IndexBadge(
                                  index: widget.index,
                                  selected: widget.selected,
                                  width: Sizes.index,
                                  height: lead,
                                ),
                                SizedBox(width: gap),
                                _Lead(
                                  item: item,
                                  compact: compact,
                                  active: _active,
                                ),
                                SizedBox(width: gap),
                                Expanded(
                                  child: Text(
                                    _metaLine(item),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: metaStyle.copyWith(color: c.text3),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: context.sp(Sizes.timeCol),
                                  child: Visibility(
                                    visible: !_active,
                                    maintainSize: true,
                                    maintainAnimation: true,
                                    maintainState: true,
                                    child: Text(
                                      relativeTime(item.timestamp),
                                      textAlign: TextAlign.right,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: metaStyle.copyWith(color: c.text3),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: compact ? 6 : 8),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: c.surface,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: _isImage
                                  ? _InlineImage(
                                      item: item,
                                      height: compact ? 48 : 64,
                                      active: _active,
                                      onPreview: widget.onPreview,
                                    )
                                  : _ClipContent(
                                      item: item,
                                      query: widget.query,
                                      maxLines: maxLines,
                                      onPreview: widget.onPreview,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_active)
                      Positioned(
                        top: padY - 4,
                        right: 8,
                        child: _ItemActions(
                          id: item.id,
                          onPreview: widget.onPreview,
                          onCopy: widget.onCopy,
                          onDelete: widget.onDelete,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _IndexBadge extends StatelessWidget {
  const _IndexBadge({
    required this.index,
    required this.selected,
    required this.width,
    required this.height,
  });
  final int index;
  final bool selected;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final w = context.sp(width);
    final h = context.sp(height);
    if (index < 1) return SizedBox(width: w, height: h);
    if (index > 9) {
      return SizedBox(
        width: w,
        height: h,
        child: Center(
          child: Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(color: c.text4, shape: BoxShape.circle),
          ),
        ),
      );
    }
    return Container(
      width: w,
      height: h,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: selected ? c.borderStrong : c.border),
      ),
      child: Text(
        '$index',
        style: TextStyle(
          fontSize: 11,
          height: 1,
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
    final c = context.c;
    final size = compact
        ? Size(context.sp(Sizes.leadCompactW), context.sp(Sizes.leadCompactH))
        : Size(context.sp(Sizes.leadW), context.sp(Sizes.leadH));
    return SizedBox.fromSize(
      size: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.leadBg,
          borderRadius: BorderRadius.circular(4),
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

class _ClipContent extends StatelessWidget {
  const _ClipContent({
    required this.item,
    required this.query,
    required this.maxLines,
    required this.onPreview,
  });

  final ClipboardItem item;
  final String query;
  final int maxLines;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final style = TextStyle(
      fontSize: 12,
      height: 18 / 12,
      letterSpacing: 0,
      color: c.text,
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      fontFeatures: const [
        FontFeature.disable('liga'),
        FontFeature.disable('calt'),
        FontFeature.tabularFigures(),
      ],
    );
    final text = displayTextOf(item);

    return LayoutBuilder(
      builder: (context, box) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: box.maxWidth);
        final totalLines = tp.computeLineMetrics().length;
        final overflows = totalLines > maxLines;
        final hidden = totalLines - maxLines;
        tp.dispose();

        final body = ExcludeSemantics(
          child: SelectionArea(
            child: Text.rich(
              highlightSpans(
                text,
                query,
                style,
                c.warn.withValues(alpha: 0.35),
              ),
              key: ValueKey('history-item-content-${item.id}'),
              maxLines: overflows ? maxLines : null,
              style: style,
            ),
          ),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (overflows)
              ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) {
                  final fade = (20 * 1.6) / rect.height;
                  return LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: const [
                      Colors.black,
                      Colors.black,
                      Colors.transparent,
                    ],
                    stops: [0, (1 - fade).clamp(0.0, 1.0), 1],
                  ).createShader(rect);
                },
                child: body,
              )
            else
              body,
            if (overflows) ...[
              const SizedBox(height: 4),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  key: ValueKey('history-item-details-${item.id}'),
                  onTap: onPreview,
                  child: Text(
                    '还有 $hidden 行 · Space 预览全文',
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 16 / 11.5,
                      color: c.text3,
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Plan A image row: a thumbnail inside the same grey content block as text
/// rows, with name and pixel size beside it. Clicking the thumbnail previews.
class _InlineImage extends StatelessWidget {
  const _InlineImage({
    required this.item,
    required this.height,
    required this.active,
    required this.onPreview,
  });
  final ClipboardItem item;
  final double height;
  final bool active;
  final VoidCallback onPreview;

  static const maxWidth = 160.0;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final iw = item.imageWidth ?? 0;
    final ih = item.imageHeight ?? 0;
    final aspect = (iw > 0 && ih > 0) ? iw / ih : 4 / 3;
    final rawWidth = height * aspect;
    final width = rawWidth.clamp(height * 0.5, maxWidth).toDouble();
    final fit = rawWidth == width ? BoxFit.fill : BoxFit.cover;
    final size = _imageSize(item);
    final dpr = MediaQuery.devicePixelRatioOf(context);

    final thumb = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: c.imgHairline),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder<Uint8List?>(
                future: getImageData(item.id),
                builder: (context, snap) {
                  final bytes = snap.data;
                  if (bytes == null) {
                    return ColoredBox(
                      color: c.leadBg,
                      child: Icon(LucideIcons.image, size: 18, color: c.text3),
                    );
                  }
                  Widget img = Image.memory(
                    bytes,
                    fit: fit,
                    width: width,
                    height: height,
                    cacheWidth: (width * dpr * 1.5).round(),
                    filterQuality: FilterQuality.medium,
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
                  return ColoredBox(color: c.bg, child: img);
                },
              ),
              AnimatedOpacity(
                opacity: active ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: ColoredBox(
                  color: const Color(0x52000000),
                  child: Center(
                    child: Icon(
                      LucideIcons.maximize2,
                      size: height < 56 ? 14 : 16,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Tooltip(
          message: '预览 (Space)',
          child: MouseRegion(
            cursor: SystemMouseCursors.zoomIn,
            child: GestureDetector(
              key: ValueKey('history-item-thumb-${item.id}'),
              onTap: onPreview,
              child: thumb,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _imageName(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 17 / 12,
                  fontWeight: FontWeight.w600,
                  color: c.text,
                ),
              ),
              if (size != null)
                Text(
                  size,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 11,
                    height: 16 / 11,
                    color: c.text2,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              if (active && height >= 56)
                Text(
                  '点缩略图或按 Space 预览',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 16 / 11,
                    color: c.accent,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ItemActions extends StatelessWidget {
  const _ItemActions({
    required this.id,
    required this.onPreview,
    required this.onCopy,
    required this.onDelete,
  });
  final BigInt id;
  final VoidCallback onPreview;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final buttons = <Widget>[
      _ActionBtn(
        key: ValueKey('history-item-preview-$id'),
        icon: LucideIcons.eye,
        tooltip: '预览 (Space)',
        onTap: onPreview,
      ),
      _ActionBtn(icon: LucideIcons.copy, tooltip: '复制 (Enter)', onTap: onCopy),
      _ActionBtn(
        icon: LucideIcons.trash2,
        tooltip: '删除 (Del)',
        danger: true,
        onTap: onDelete,
      ),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final w in buttons)
          Container(
            margin: const EdgeInsets.only(left: 2),
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: c.border),
            ),
            child: w,
          ),
      ],
    );
  }
}

class _ActionBtn extends StatefulWidget {
  const _ActionBtn({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });
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
