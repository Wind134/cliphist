import 'package:flutter/material.dart';

import 'theme.dart';

/// Category filter tabs. Modern pill chips: each carries a small colored dot
/// (the type accent) + label; the active chip is filled with a soft accent tint
/// and the type-colored dot, the rest sit on a subtle surface. Horizontally
/// scrollable so a narrow window still reaches every tab.
class CategoryTabs extends StatelessWidget {
  const CategoryTabs({
    super.key,
    required this.current,
    required this.onChanged,
  });

  final String current;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return Container(
      height: 42 + (scale - 1).clamp(0, 1).toDouble() * 12,
      decoration: const BoxDecoration(
        color: CliphistColors.surface,
        border: Border(bottom: BorderSide(color: CliphistColors.borderSubtle)),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 7),
        itemCount: ClipType.byKey.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final t = ClipType.byKey[i];
          final active = t.key == current;
          return _Chip(
            label: t.label,
            active: active,
            onTap: () => onChanged(t.key),
          );
        },
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: active ? CliphistColors.accentSoft : CliphistColors.surface,
            borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
            border: Border.all(
              color: active
                  ? CliphistColors.accent.withValues(alpha: 0.35)
                  : CliphistColors.borderSubtle,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Dot(
                color: active
                    ? CliphistColors.accent
                    : CliphistColors.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: active
                      ? CliphistColors.accentHover
                      : CliphistColors.textSecondary,
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}
