import 'package:flutter/material.dart';

import 'theme.dart';

/// Shared header chrome so history and settings sit on the same grid:
/// 12px side gutters, 36px leading, 32px actions, 6px gaps.
class CliphistHeaderBar extends StatelessWidget {
  const CliphistHeaderBar({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.actions,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final List<Widget> actions;

  static const double height = 56;
  static const double leadingSize = 36;
  static const double actionSize = 32;
  static const double actionGap = 6;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: height),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: CliphistColors.surface,
        border: Border(bottom: BorderSide(color: CliphistColors.borderSubtle)),
      ),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: CliphistColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    letterSpacing: -0.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: CliphistColors.textMuted,
                    fontSize: 12,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(width: 10),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: actionGap),
                  actions[i],
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class CliphistHeaderBadge extends StatelessWidget {
  const CliphistHeaderBadge({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: CliphistHeaderBar.leadingSize,
      height: CliphistHeaderBar.leadingSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: CliphistColors.accentSoft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }
}

/// 32px header control. Icon-only, or icon+label on one optical midline.
/// Built as Material+InkWell (not TextButton.icon): M3's icon button
/// `height: 1` + `maximumSize` squashed CJK and sat the label below the icon.
class CliphistHeaderButton extends StatelessWidget {
  const CliphistHeaderButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.label,
    this.accent = false,
    this.alwaysLabeled = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final String? label;
  final bool accent;
  final bool alwaysLabeled;

  @override
  Widget build(BuildContext context) {
    final compact =
        label == null ||
        (!alwaysLabeled && MediaQuery.sizeOf(context).width < 360);
    final fg = accent ? CliphistColors.accent : CliphistColors.textSecondary;
    final bg = accent
        ? CliphistColors.accentSoft
        : CliphistColors.surfaceSubtle;
    final border = accent
        ? CliphistColors.accent.withValues(alpha: 0.18)
        : CliphistColors.borderSubtle;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
    );

    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        elevation: 0,
        shape: shape.copyWith(side: BorderSide(color: border)),
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          hoverColor: accent ? CliphistColors.selected : CliphistColors.hover,
          child: ConstrainedBox(
            constraints: compact
                ? const BoxConstraints.tightFor(
                    width: CliphistHeaderBar.actionSize,
                    height: CliphistHeaderBar.actionSize,
                  )
                : const BoxConstraints(
                    minHeight: CliphistHeaderBar.actionSize,
                    maxHeight: CliphistHeaderBar.actionSize,
                  ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(icon, size: 16, color: fg),
                  if (!compact) ...[
                    const SizedBox(width: 5),
                    Text(
                      label!,
                      style: TextStyle(
                        color: fg,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                      strutStyle: const StrutStyle(
                        fontSize: 12,
                        height: 1.2,
                        leading: 0,
                        forceStrutHeight: true,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
