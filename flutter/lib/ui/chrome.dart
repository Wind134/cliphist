import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

import 'theme.dart';

class AppTitleBar extends StatelessWidget {
  const AppTitleBar({
    super.key,
    required this.leading,
    this.prefix,
    this.actions = const [],
  });

  /// Interactive control before the drag region (settings back button).
  final Widget? prefix;
  final Widget leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(
      height: Sizes.titleBar,
      child: Row(
        children: [
          if (isMac) const SizedBox(width: 78),
          if (prefix != null)
            Padding(
              padding: EdgeInsets.only(left: isMac ? 0 : 8),
              child: prefix!,
            ),
          Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: isMac || prefix != null ? 0 : 12,
                ),
                child: leading,
              ),
            ),
          ),
          ...actions,
          if (!isMac) ...[
            Container(
              width: 1,
              height: 16,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              color: c.border,
            ),
            if (isLinux) const _GnomeButtons() else const _WinCaptionButtons(),
          ] else
            const SizedBox(width: 6),
        ],
      ),
    );
  }
}

class CountPill extends StatelessWidget {
  const CountPill(this.count, {super.key});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 1, 7, 1),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 11,
          height: 16 / 11,
          fontWeight: FontWeight.w600,
          color: c.text2,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class IconBtn extends StatefulWidget {
  const IconBtn({
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
  State<IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<IconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final fg = widget.danger && _hover ? c.danger : (_hover ? c.text : c.text2);
    final bg = widget.danger && _hover
        ? c.danger.withValues(alpha: 0.10)
        : (_hover ? c.hover : Colors.transparent);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 28,
            height: 28,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(widget.icon, size: 16, color: fg),
          ),
        ),
      ),
    );
  }
}

class _WinCaptionButtons extends StatelessWidget {
  const _WinCaptionButtons();

  @override
  Widget build(BuildContext context) => const Row(
    children: [
      _CaptionButton(icon: _CaptionIcon.minimize),
      _CaptionButton(icon: _CaptionIcon.close, isClose: true),
    ],
  );
}

enum _CaptionIcon { minimize, close }

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({required this.icon, this.isClose = false});
  final _CaptionIcon icon;
  final bool isClose;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bg = widget.isClose
        ? (_down
              ? const Color(0xFFA52517)
              : _hover
              ? c.winClose
              : Colors.transparent)
        : (_down
              ? c.surfaceHover
              : _hover
              ? c.hover
              : Colors.transparent);
    final fg = widget.isClose && _hover
        ? Colors.white
        : c.text.withValues(alpha: 0.85);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) {
          setState(() => _down = false);
          if (widget.isClose) {
            unawaited(windowManager.close());
          } else {
            unawaited(windowManager.minimize());
          }
        },
        onTapCancel: () => setState(() => _down = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 44,
          height: 40,
          color: bg,
          child: Center(
            child: CustomPaint(
              size: const Size(10, 10),
              painter: _GlyphPainter(widget.icon, fg),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.icon, this.color);
  final _CaptionIcon icon;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    if (icon == _CaptionIcon.minimize) {
      canvas.drawLine(
        Offset(0, s.height / 2),
        Offset(s.width, s.height / 2),
        p,
      );
    } else {
      canvas.drawLine(Offset.zero, Offset(s.width, s.height), p);
      canvas.drawLine(Offset(s.width, 0), Offset(0, s.height), p);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter o) => o.color != color || o.icon != icon;
}

class _GnomeButtons extends StatelessWidget {
  const _GnomeButtons();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(left: 4, right: 8),
      child: Row(
        children: [
          _RoundBtn(icon: LucideIcons.minus, minimize: true),
          SizedBox(width: 10),
          _RoundBtn(icon: LucideIcons.x, danger: true),
        ],
      ),
    );
  }
}

class _RoundBtn extends StatefulWidget {
  const _RoundBtn({
    required this.icon,
    this.danger = false,
    this.minimize = false,
  });
  final IconData icon;
  final bool danger;
  final bool minimize;

  @override
  State<_RoundBtn> createState() => _RoundBtnState();
}

class _RoundBtnState extends State<_RoundBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bg = widget.danger && _hover
        ? c.danger
        : (_hover ? c.surfaceHover : c.surface);
    final fg = widget.danger && _hover ? Colors.white : c.text2;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () {
          if (widget.minimize) {
            unawaited(windowManager.minimize());
          } else {
            unawaited(windowManager.close());
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 22,
          height: 22,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Icon(widget.icon, size: 10, color: fg),
        ),
      ),
    );
  }
}
