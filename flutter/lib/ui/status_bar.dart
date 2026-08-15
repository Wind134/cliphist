import 'package:flutter/material.dart';

import 'theme.dart';

/// Bottom status bar, ported from `src/lib/statusbar.svelte`: shows the
/// monitoring state on the left, and the interaction hints ("双击或 Enter 复制 ·
/// 1-9 快捷输入") on the right.
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
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: CliphistColors.bgSecondary,
        border: Border(
          top: BorderSide(color: CliphistColors.border, width: 1),
        ),
      ),
      child: Row(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                helperConnected ? Icons.link : Icons.link_off,
                size: 11,
                color: helperConnected
                    ? const Color(0xFF059669)
                    : CliphistColors.textTertiary,
              ),
              const SizedBox(width: 4),
              Text(
                helperConnected ? '监听中' : '未连接',
                style: const TextStyle(
                  color: CliphistColors.textTertiary,
                  fontSize: 11,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$count',
                style: const TextStyle(
                  color: CliphistColors.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const Spacer(),
          const Text(
            '双击或 Enter 复制 · 1-9 快捷输入',
            style: TextStyle(color: CliphistColors.textTertiary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}