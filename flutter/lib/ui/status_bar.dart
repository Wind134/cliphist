import 'package:flutter/material.dart';

import 'kbd.dart';
import 'theme.dart';

class StatusBar extends StatelessWidget {
  const StatusBar({
    super.key,
    required this.helperConnected,
    this.gameMode = false,
    this.doubleTapKey = '',
  });

  final bool helperConnected;
  final bool gameMode;
  final String doubleTapKey;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final paused = gameMode;
    final ready = helperConnected && !paused;
    final keyLabel = doubleTapKey.isEmpty
        ? (isMac ? '⌘' : 'Ctrl')
        : (isMac
              ? {'Ctrl': '⌘', 'Shift': '⇧', 'Alt': '⌥'}[doubleTapKey] ??
                    doubleTapKey
              : doubleTapKey);
    final label = paused
        ? '游戏模式 · 双击已暂停'
        : ready
        ? '双击 $keyLabel 已就绪'
        : doubleTapKey.isEmpty
        ? '双击键未启用'
        : '双击键未启用';

    return Container(
      height: Sizes.footer,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.bgSub,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          _StatusDot(active: ready, warn: paused),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.text3,
                fontSize: 11,
                height: 15 / 11,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          if (MediaQuery.sizeOf(context).width > 330) ...[
            Kbd('↵', compact: true),
            const SizedBox(width: 4),
            Text('复制', style: TextStyle(color: c.text3, fontSize: 11)),
            const SizedBox(width: 8),
            Kbd('1', compact: true),
            Text('–', style: TextStyle(color: c.text4, fontSize: 11)),
            Kbd('9', compact: true),
            const SizedBox(width: 4),
            Text('快捷', style: TextStyle(color: c.text3, fontSize: 11)),
            const SizedBox(width: 8),
            Kbd('Del', compact: true),
            const SizedBox(width: 4),
            Text('删除', style: TextStyle(color: c.text3, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.active, required this.warn});
  final bool active;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = warn
        ? c.warn
        : active
        ? c.success
        : c.text4;
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.20),
            blurRadius: 0,
            spreadRadius: 3,
          ),
        ],
      ),
    );
  }
}
