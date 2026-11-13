import 'package:flutter/material.dart';

import 'theme.dart';

/// Small keyboard-key glyph used in the search field, footer and index badge.
class Kbd extends StatelessWidget {
  const Kbd(this.label, {super.key, this.muted = false, this.compact = false});

  final String label;
  final bool muted;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      constraints: BoxConstraints(
        minWidth: compact ? 18 : 17,
        minHeight: compact ? 18 : 17,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: muted ? Colors.transparent : c.kbdBg,
        borderRadius: BorderRadius.circular(4),
        border: Border(
          top: BorderSide(color: muted ? c.border : c.kbdBorder),
          left: BorderSide(color: muted ? c.border : c.kbdBorder),
          right: BorderSide(color: muted ? c.border : c.kbdBorder),
          bottom: BorderSide(
            color: muted ? c.border : c.kbdBorder,
            width: muted ? 1 : 2,
          ),
        ),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 10.5,
          height: 14 / 10.5,
          fontWeight: FontWeight.w500,
          color: muted ? c.text3 : c.text2,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
