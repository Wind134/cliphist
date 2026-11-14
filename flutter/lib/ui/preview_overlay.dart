import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/scheduler.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../src/rust/core/clipboard_engine.dart' show ClipboardItem;
import '../util/image_cache.dart';
import 'history_item.dart';
import 'theme.dart';

/// In-window preview layer shared by every clip type. The host
/// ([HistoryView]) owns the keyboard: Esc / Space close, ←/→ switch items and
/// Enter copies, so this widget only renders and exposes pointer actions.
class PreviewOverlay extends StatelessWidget {
  const PreviewOverlay({
    super.key,
    required this.item,
    required this.query,
    required this.onClose,
    required this.onCopy,
    required this.onCopySelection,
    this.onPrev,
    this.onNext,
  });

  final ClipboardItem item;
  final String query;
  final VoidCallback onClose;

  /// Copies the whole item (same path as Enter in the list).
  final VoidCallback onCopy;

  /// Copies a partial text selection made inside the preview.
  final ValueChanged<String> onCopySelection;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return TweenAnimationBuilder<double>(
      key: const ValueKey('preview-overlay'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(scale: 0.98 + 0.02 * t, child: child),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('preview-backdrop'),
              behavior: HitTestBehavior.opaque,
              onTap: onClose,
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
                  child: ColoredBox(
                    color: dark
                        ? const Color(0x8C000000)
                        : const Color(0x5218181B),
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 36, 12, 36),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  // Shadow sits outside the clipped card; inside it would
                  // show through the transparent body and grey it out.
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: dark ? 0.5 : 0.18,
                          ),
                          blurRadius: 32,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Material(
                      color: c.bg,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: c.border),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: _PreviewCard(
                        key: ValueKey('preview-card-${item.id}'),
                        item: item,
                        query: query,
                        onClose: onClose,
                        onCopy: onCopy,
                        onCopySelection: onCopySelection,
                        onPrev: onPrev,
                        onNext: onNext,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _Kind { image, text, rich, link, files }

_Kind _kindOf(ClipboardItem item) => switch (item.contentType) {
  'image' => _Kind.image,
  'link' => _Kind.link,
  'files' => _Kind.files,
  'rich' when (item.htmlContent ?? '').trim().isNotEmpty => _Kind.rich,
  _ => _Kind.text,
};

class _PreviewCard extends StatefulWidget {
  const _PreviewCard({
    super.key,
    required this.item,
    required this.query,
    required this.onClose,
    required this.onCopy,
    required this.onCopySelection,
    this.onPrev,
    this.onNext,
  });

  final ClipboardItem item;
  final String query;
  final VoidCallback onClose;
  final VoidCallback onCopy;
  final ValueChanged<String> onCopySelection;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  State<_PreviewCard> createState() => _PreviewCardState();
}

class _PreviewCardState extends State<_PreviewCard> {
  /// Text: false = 原文 (no wrap, horizontal scroll), true = 自动换行.
  bool _wrap = false;

  /// Rich: true = 渲染, false = 纯文本.
  bool _rendered = true;
  final ValueNotifier<String> _selection = ValueNotifier('');
  final TransformationController _zoom = TransformationController();
  final ValueNotifier<double> _zoomScale = ValueNotifier(1);
  Size _viewport = Size.zero;

  ClipboardItem get item => widget.item;
  _Kind get kind => _kindOf(item);

  @override
  void initState() {
    super.initState();
    _zoom.addListener(() => _zoomScale.value = _zoom.value.getMaxScaleOnAxis());
  }

  @override
  void dispose() {
    _selection.dispose();
    _zoom.dispose();
    _zoomScale.dispose();
    super.dispose();
  }

  void _onSelectionChanged(SelectedContent? content) {
    final text = content?.plainText ?? '';
    void apply() {
      if (mounted) _selection.value = text;
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  // ---- image zoom -------------------------------------------------------

  void _setScale(double scale) {
    final s = scale.clamp(0.1, 20.0);
    final cx = _viewport.width / 2;
    final cy = _viewport.height / 2;
    _zoom.value = Matrix4.identity()
      ..translateByDouble(cx, cy, 0, 1)
      ..scaleByDouble(s, s, 1, 1)
      ..translateByDouble(-cx, -cy, 0, 1);
  }

  void _zoomBy(double factor) =>
      _setScale(_zoom.value.getMaxScaleOnAxis() * factor);

  void _fit() => _zoom.value = Matrix4.identity();

  void _actualSize() {
    final iw = (item.imageWidth ?? 0).toDouble();
    final ih = (item.imageHeight ?? 0).toDouble();
    if (iw <= 0 || ih <= 0 || _viewport.isEmpty) return;
    final fit = math.min(_viewport.width / iw, _viewport.height / ih);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    _setScale(1 / (dpr * fit));
  }

  Future<void> _openImageExternally() async {
    try {
      final bytes = await getImageData(item.id);
      if (bytes == null) return;
      final dir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}cliphist-preview',
      );
      await dir.create(recursive: true);
      final file = File(
        '${dir.path}${Platform.pathSeparator}cliphist-${item.id}.png',
      );
      await file.writeAsBytes(bytes, flush: true);
      await _openPath(file.path);
    } catch (_) {}
  }

  // ---- build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(c),
        Divider(height: 1, color: c.border),
        Expanded(child: _body(c)),
        Divider(height: 1, color: c.border),
        _footer(c),
      ],
    );
  }

  Widget _header(AppColors c) {
    final meta = _headerMeta();
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 6),
        child: Row(
          children: [
            Icon(typeIconOf(item), size: 15, color: c.text2),
            const SizedBox(width: 8),
            Text(
              typeLabelOf(item),
              style: TextStyle(
                fontSize: 13,
                height: 18 / 13,
                fontWeight: FontWeight.w600,
                color: c.text,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.2,
                  color: c.text3,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (kind == _Kind.text)
              _Segmented(
                labels: const ['原文', '自动换行'],
                index: _wrap ? 1 : 0,
                onChanged: (i) => setState(() => _wrap = i == 1),
              ),
            if (kind == _Kind.rich)
              _Segmented(
                labels: const ['渲染', '纯文本'],
                index: _rendered ? 0 : 1,
                onChanged: (i) => setState(() => _rendered = i == 0),
              ),
            const SizedBox(width: 4),
            _IconButton(
              key: const ValueKey('preview-close'),
              icon: LucideIcons.x,
              tooltip: '关闭 (Esc)',
              onTap: widget.onClose,
            ),
          ],
        ),
      ),
    );
  }

  String _headerMeta() {
    switch (kind) {
      case _Kind.image:
        final w = item.imageWidth ?? 0;
        final h = item.imageHeight ?? 0;
        return (w > 0 && h > 0) ? '$w × $h px' : '';
      case _Kind.files:
        return '${filePathsOf(item).length} 个文件';
      case _Kind.link:
        return Uri.tryParse(item.content.trim())?.host ?? '';
      case _Kind.text:
      case _Kind.rich:
        final text = displayTextOf(item);
        final lines = '\n'.allMatches(text).length + 1;
        return '${item.charCount.toInt()} 字 · $lines 行';
    }
  }

  Widget _body(AppColors c) {
    switch (kind) {
      case _Kind.image:
        return _imageBody(c);
      case _Kind.text:
        return _TextBody(
          text: displayTextOf(item),
          query: widget.query,
          wrap: _wrap,
          contentKey: ValueKey('history-item-full-content-${item.id}'),
          onSelectionChanged: _onSelectionChanged,
        );
      case _Kind.rich:
        if (!_rendered) {
          return _TextBody(
            text: displayTextOf(item),
            query: widget.query,
            wrap: true,
            contentKey: ValueKey('history-item-full-content-${item.id}'),
            onSelectionChanged: _onSelectionChanged,
          );
        }
        return SelectionArea(
          onSelectionChanged: _onSelectionChanged,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: HtmlWidget(
              item.htmlContent ?? '',
              key: ValueKey('history-item-full-content-${item.id}'),
              textStyle: TextStyle(fontSize: 13, height: 1.5, color: c.text),
              // Never fetch remote resources or follow links from clipboard
              // HTML: images are dropped and taps are swallowed.
              customWidgetBuilder: (e) => switch (e.localName) {
                'img' ||
                'video' ||
                'audio' ||
                'iframe' ||
                'object' ||
                'embed' => const SizedBox.shrink(),
                _ => null,
              },
              onTapUrl: (_) => true,
            ),
          ),
        );
      case _Kind.link:
        return _linkBody(c);
      case _Kind.files:
        return _filesBody(c);
    }
  }

  Widget _imageBody(AppColors c) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      color: c.bgSub,
      child: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, box) {
                _viewport = box.biggest;
                return InteractiveViewer(
                  transformationController: _zoom,
                  minScale: 0.1,
                  maxScale: 20,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  child: SizedBox.fromSize(
                    size: box.biggest,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: FutureBuilder<Uint8List?>(
                        future: getImageData(item.id),
                        builder: (context, snap) {
                          final bytes = snap.data;
                          if (bytes == null) {
                            return Center(
                              child: Icon(
                                LucideIcons.image,
                                size: 28,
                                color: c.text4,
                              ),
                            );
                          }
                          return Image.memory(
                            bytes,
                            key: ValueKey('preview-image-${item.id}'),
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.medium,
                            gaplessPlayback: true,
                            color: dark ? const Color(0x14000000) : null,
                            colorBlendMode: dark ? BlendMode.srcATop : null,
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            child: Center(child: _zoomBar(c)),
          ),
        ],
      ),
    );
  }

  Widget _zoomBar(AppColors c) {
    const fg = Color(0xFFF4F4F5);
    Widget btn(String label, VoidCallback onTap, {String? tooltip, Key? key}) {
      return Tooltip(
        message: tooltip ?? '',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: key,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              child: Text(
                label,
                style: const TextStyle(fontSize: 12, height: 1.2, color: fg),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: const Color(0xCC1F1F23),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          btn('−', () => _zoomBy(1 / 1.25), tooltip: '缩小'),
          btn('适应窗口', _fit, key: const ValueKey('preview-zoom-fit')),
          btn('+', () => _zoomBy(1.25), tooltip: '放大'),
          btn('1:1', _actualSize, tooltip: '实际像素'),
          ValueListenableBuilder<double>(
            valueListenable: _zoomScale,
            builder: (_, s, _) => Padding(
              padding: const EdgeInsets.only(left: 2, right: 6),
              child: Text(
                '${(s * 100).round()}%',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.2,
                  color: fg.withValues(alpha: 0.6),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _linkBody(AppColors c) {
    final url = item.content.trim();
    final uri = Uri.tryParse(url);
    return SelectionArea(
      onSelectionChanged: _onSelectionChanged,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((uri?.host ?? '').isNotEmpty) ...[
              Text(
                uri!.host,
                style: TextStyle(
                  fontSize: 14,
                  height: 20 / 14,
                  fontWeight: FontWeight.w600,
                  color: c.text,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text.rich(
                highlightSpans(
                  url,
                  widget.query,
                  _monoStyle(c),
                  c.warn.withValues(alpha: 0.35),
                ),
                key: ValueKey('history-item-full-content-${item.id}'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filesBody(AppColors c) {
    final paths = filePathsOf(item);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      itemCount: paths.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        final p = paths[i];
        final name = p.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty);
        return Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.file, size: 16, color: c.text2),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? p : name.last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 17 / 12.5,
                        fontWeight: FontWeight.w500,
                        color: c.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(
                      p,
                      style: _monoStyle(c).copyWith(
                        fontSize: 11.5,
                        height: 16 / 11.5,
                        color: c.text2,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _FooterButton(
                label: '在资源管理器中显示',
                onTap: () => unawaited(_revealInFolder(p)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _footer(AppColors c) {
    final hintStyle = TextStyle(fontSize: 11.5, height: 1.2, color: c.text3);
    final left = switch (kind) {
      _Kind.text || _Kind.rich || _Kind.link => ValueListenableBuilder<String>(
        valueListenable: _selection,
        builder: (_, sel, _) => sel.isEmpty
            ? _switchHint(hintStyle)
            : Text('已选中 ${sel.runes.length} 字', style: hintStyle),
      ),
      _ => _switchHint(hintStyle),
    };
    final buttons = <Widget>[
      if (kind == _Kind.image)
        _FooterButton(
          label: '用系统看图打开',
          onTap: () => unawaited(_openImageExternally()),
        ),
      if (kind == _Kind.link)
        _FooterButton(
          label: '在浏览器打开',
          onTap: () => unawaited(_openUrl(item.content.trim())),
        ),
      if (kind == _Kind.text || kind == _Kind.rich || kind == _Kind.link)
        ValueListenableBuilder<String>(
          valueListenable: _selection,
          builder: (_, sel, _) => _FooterButton(
            key: const ValueKey('preview-copy-selection'),
            label: '复制所选',
            onTap: sel.isEmpty ? null : () => widget.onCopySelection(sel),
          ),
        ),
      _FooterButton(
        key: const ValueKey('preview-copy'),
        label: kind == _Kind.text || kind == _Kind.rich ? '复制全部 ↵' : '复制 ↵',
        primary: true,
        onTap: widget.onCopy,
      ),
    ];
    return SizedBox(
      height: 46,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Expanded(child: left),
            for (final b in buttons) ...[const SizedBox(width: 6), b],
          ],
        ),
      ),
    );
  }

  Widget _switchHint(TextStyle style) {
    final c = context.c;
    return Row(
      children: [
        _IconButton(
          icon: LucideIcons.chevronLeft,
          tooltip: '上一条 (←)',
          small: true,
          onTap: widget.onPrev,
        ),
        _IconButton(
          icon: LucideIcons.chevronRight,
          tooltip: '下一条 (→)',
          small: true,
          onTap: widget.onNext,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            '切换条目',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style.copyWith(color: c.text3),
          ),
        ),
      ],
    );
  }
}

TextStyle _monoStyle(AppColors c) => TextStyle(
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

/// Full text with a line-number gutter. Numbers are positioned from the laid
/// out paragraph so they stay on the first visual line of each logical line
/// in 自动换行 mode. The content stays a single [Text] so a selection copies
/// exactly the original characters and newlines.
class _TextBody extends StatefulWidget {
  const _TextBody({
    required this.text,
    required this.query,
    required this.wrap,
    required this.contentKey,
    required this.onSelectionChanged,
  });

  final String text;
  final String query;
  final bool wrap;
  final Key contentKey;
  final ValueChanged<SelectedContent?> onSelectionChanged;

  @override
  State<_TextBody> createState() => _TextBodyState();
}

class _TextBodyState extends State<_TextBody> {
  final ScrollController _v = ScrollController();
  final ScrollController _h = ScrollController();

  @override
  void dispose() {
    _v.dispose();
    _h.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final style = _monoStyle(c);
    final text = widget.text;
    final scaler = MediaQuery.textScalerOf(context);
    final lineStarts = <int>[0];
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) lineStarts.add(i + 1);
    }
    final digits = '${lineStarts.length}'.length;
    final numStyle = style.copyWith(color: c.text4);
    final gutter = scaler.scale(12) * 0.62 * math.max(2, digits) + 14;
    const padL = 10.0, padR = 16.0, padY = 12.0;

    return LayoutBuilder(
      builder: (context, box) {
        final contentW = math.max(40.0, box.maxWidth - gutter - padL - padR);
        final tp = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout(maxWidth: widget.wrap ? contentW : double.infinity);
        final tops = <double>[
          for (final s in lineStarts)
            tp.getOffsetForCaret(TextPosition(offset: s), Rect.zero).dy,
        ];
        final height = tp.height;
        final lineH = scaler.scale(18);
        tp.dispose();

        final content = Text.rich(
          highlightSpans(
            text,
            widget.query,
            style,
            c.warn.withValues(alpha: 0.35),
          ),
          key: widget.contentKey,
          softWrap: widget.wrap,
          style: style,
        );

        return Scrollbar(
          controller: _v,
          child: SingleChildScrollView(
            controller: _v,
            padding: const EdgeInsets.symmetric(vertical: padY),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: gutter,
                  height: height,
                  child: Stack(
                    children: [
                      for (var i = 0; i < tops.length; i++)
                        Positioned(
                          top: tops[i],
                          right: 0,
                          height: lineH,
                          child: Text('${i + 1}', style: numStyle),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: padL),
                Expanded(
                  child: SelectionArea(
                    onSelectionChanged: widget.onSelectionChanged,
                    child: widget.wrap
                        ? Padding(
                            padding: const EdgeInsets.only(right: padR),
                            child: content,
                          )
                        : Scrollbar(
                            controller: _h,
                            child: SingleChildScrollView(
                              controller: _h,
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.only(
                                right: padR,
                                bottom: 10,
                              ),
                              child: content,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.labels,
    required this.index,
    required this.onChanged,
  });
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < labels.length; i++)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                key: ValueKey('preview-seg-${labels[i]}'),
                onTap: () => onChanged(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: i == index ? c.bg : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: i == index ? c.selBorder : Colors.transparent,
                    ),
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.25,
                      fontWeight: i == index
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: i == index ? c.accent : c.text2,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _IconButton extends StatefulWidget {
  const _IconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.small = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool small;

  @override
  State<_IconButton> createState() => _IconButtonState();
}

class _IconButtonState extends State<_IconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final enabled = widget.onTap != null;
    final size = widget.small ? 22.0 : 28.0;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: _hover && enabled ? c.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              widget.icon,
              size: widget.small ? 14 : 15,
              color: !enabled
                  ? c.text4
                  : _hover
                  ? c.text
                  : c.text3,
            ),
          ),
        ),
      ),
    );
  }
}

class _FooterButton extends StatefulWidget {
  const _FooterButton({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
  });
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  State<_FooterButton> createState() => _FooterButtonState();
}

class _FooterButtonState extends State<_FooterButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final enabled = widget.onTap != null;
    final bg = widget.primary
        ? (_hover ? c.accentHover : c.accent)
        : (_hover && enabled ? c.surface : c.bg);
    final fg = widget.primary
        ? c.onAccent
        : enabled
        ? c.text
        : c.text4;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: widget.primary ? Colors.transparent : c.borderStrong,
            ),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            style: TextStyle(
              fontSize: 12,
              height: 1.2,
              fontWeight: widget.primary ? FontWeight.w600 : FontWeight.w500,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _openPath(String path) async {
  final uri = Uri.file(path, windows: Platform.isWindows);
  try {
    if (await launchUrl(uri)) return;
  } catch (_) {}
  if (Platform.isWindows) {
    await Process.run('cmd', ['/c', 'start', '', path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [path]);
  } else {
    await Process.run('xdg-open', [path]);
  }
}

Future<void> _openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https' && scheme != 'mailto') return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
}

Future<void> _revealInFolder(String raw) async {
  try {
    final path = raw.startsWith('file:') ? Uri.parse(raw).toFilePath() : raw;
    if (Platform.isWindows) {
      await Process.run('explorer', ['/select,${path.replaceAll('/', r'\')}']);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else {
      final file = File(path);
      final dir = await FileSystemEntity.isDirectory(path)
          ? Directory(path)
          : file.parent;
      await _openPath(dir.path);
    }
  } catch (_) {}
}
