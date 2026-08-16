import 'package:flutter/material.dart';

import 'theme.dart';

/// Bottom status bar: monitoring indicator (animated dot + label) on the
/// left, interaction hints on the right. Refined to a slim, quiet strip.
class StatusBar extends StatelessWidget {
  const StatusBar({
    super.key,
    required this.helperConnected,
    required this.count,
  });

  final bool helperConnected;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: CliphistColors.surface,
        border: Border(
          top: BorderSide(color: CliphistColors.borderSubtle, width: 1),
        ),
      ),
      child: Row(
        children: [
          _StatusDot(active: helperConnected),
          const SizedBox(width: 6),
          Text(
            helperConnected ? '监听中' : '未连接',
            style: TextStyle(
              color: helperConnected
                  ? CliphistColors.success
                  : CliphistColors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '$count 条',
            style: const TextStyle(
              color: CliphistColors.textMuted,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const Spacer(),
          const Text(
            '双击 / Enter 复制 · 1–9 快捷',
            style: TextStyle(color: CliphistColors.textMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: active ? CliphistColors.success : CliphistColors.textMuted,
        borderRadius: BorderRadius.circular(4),
        boxShadow: active
            ? const [
                BoxShadow(
                  color: Color(0x5516A34A),
                  blurRadius: 5,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
    );
  }
}