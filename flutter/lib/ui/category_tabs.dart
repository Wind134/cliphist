import 'package:flutter/material.dart';

import 'theme.dart';

class CategoryTabs extends StatelessWidget {
  const CategoryTabs({
    super.key,
    required this.current,
    required this.onChanged,
    this.counts = const {},
  });

  final String current;
  final ValueChanged<String> onChanged;
  final Map<String, int> counts;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: Sizes.chip,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: ClipType.byKey.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (_, i) {
          final t = ClipType.byKey[i];
          return _Chip(
            type: t,
            active: t.key == current,
            count: t.key == 'all' ? null : counts[t.key],
            onTap: () => onChanged(t.key),
          );
        },
      ),
    );
  }
}

class _Chip extends StatefulWidget {
  const _Chip({
    required this.type,
    required this.active,
    required this.onTap,
    this.count,
  });

  final ClipType type;
  final bool active;
  final VoidCallback onTap;
  final int? count;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bg = widget.active
        ? c.accentSoft
        : _hover
        ? c.hover
        : Colors.transparent;
    final fg = widget.active ? c.accent : (_hover ? c.text : c.text2);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: Sizes.chip,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.type.label,
                style: TextStyle(
                  fontSize: 12,
                  height: 16 / 12,
                  fontWeight: FontWeight.w500,
                  color: fg,
                ),
              ),
              if (widget.active && widget.count != null) ...[
                const SizedBox(width: 4),
                Text(
                  '${widget.count}',
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.2,
                    fontWeight: FontWeight.w500,
                    color: c.accent.withValues(alpha: 0.75),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
