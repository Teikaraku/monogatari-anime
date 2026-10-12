import 'package:flutter/material.dart';
import 'package:kazumi/utils/theme.dart';

/// The selection chip of the Monogatari apps: a grey capsule that turns into
/// an accent-tinted outline when chosen. [excluded] marks the third state of
/// include/exclude filters.
class MonoChip extends StatelessWidget {
  const MonoChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.excluded = false,
    this.checkmark = false,
    this.trailingIcon,
    this.leadingIcon,
    this.enabled = true,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final bool excluded;
  final bool checkmark;
  final IconData? trailingIcon;
  final IconData? leadingIcon;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = excluded ? colors.error : colors.primary;
    final active = selected || excluded;
    final foreground = !enabled
        ? colors.onSurface.withValues(alpha: 0.38)
        : active
            ? accent
            : colors.onSurface;
    return Semantics(
      selected: active,
      button: true,
      child: Material(
        color: active
            ? accent.withValues(alpha: 0.1)
            : MonoPalette.of(context).chip,
        shape: StadiumBorder(
          side: active
              ? BorderSide(color: accent.withValues(alpha: 0.6))
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 52, minHeight: 34),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (leadingIcon != null) ...[
                    Icon(leadingIcon, size: 16, color: foreground),
                    const SizedBox(width: 4),
                  ] else if (active && checkmark) ...[
                    Icon(excluded ? Icons.close_rounded : Icons.check_rounded,
                        size: 15, color: accent),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.2,
                        fontWeight:
                            active ? FontWeight.w500 : FontWeight.w400,
                        color: foreground,
                      ),
                    ),
                  ),
                  if (trailingIcon != null) ...[
                    const SizedBox(width: 3),
                    Icon(trailingIcon,
                        size: 16,
                        color: active ? accent : colors.onSurfaceVariant),
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
