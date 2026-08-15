import 'package:flutter/material.dart';

import 'theme.dart';

/// Category filter tabs, ported from `src/lib/category-tabs.svelte`. Six tabs
/// with per-type accent colors; the active tab is filled, the rest are
/// outlined. Laid out in a horizontally scrollable row so a narrow window
/// still reaches every tab.
class CategoryTabs extends StatelessWidget {
  const CategoryTabs({
    super.key,
    required this.current,
    required this.onChanged,
  });

  final String current;
  final ValueChanged<String> onChanged;

  static const _tabs = <_TabDef>[
    _TabDef('all', '全部', Color(0xFF4F46E5)),
    _TabDef('image', '图片', Color(0xFF059669)),
    _TabDef('text', '文本', Color(0xFF2563EB)),
    _TabDef('link', '链接', Color(0xFFDC2626)),
    _TabDef('short', '短文本', Color(0xFF7C3AED)),
    _TabDef('rich', '富文本', Color(0xFFE11D48)),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: _tabs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final t = _tabs[i];
          final active = t.key == current;
          return _Chip(
            label: t.label,
            color: t.color,
            active: active,
            onTap: () => onChanged(t.key),
          );
        },
      ),
    );
  }
}

class _TabDef {
  final String key;
  final String label;
  final Color color;
  const _TabDef(this.key, this.label, this.color);
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.color,
    required this.active,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active ? color : Colors.transparent,
            border: Border.all(
              color: active ? color : CliphistColors.border,
              width: 1,
            ),
            borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : CliphistColors.textSecondary,
              fontSize: 11,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}