import 'package:flutter/material.dart';
import 'package:kazumi/bean/widget/bangumi_avatar.dart';
import 'package:kazumi/utils/theme.dart';

/// A compact cast or staff cell for the two-column grid of the detail page:
/// avatar, name, and up to two short lines below it.
class CastTile extends StatelessWidget {
  const CastTile({
    super.key,
    required this.imageUrl,
    required this.name,
    this.subtitle = '',
    this.role = '',
    this.roleAccent = false,
    this.onTap,
  });

  /// Grid row height before text scaling.
  static const double height = 72;

  final String imageUrl;
  final String name;
  final String subtitle;
  final String role;
  final bool roleAccent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = MonoPalette.of(context);
    final cellColor = theme.brightness == Brightness.dark
        ? palette.groupedCell
        : palette.groupedBackground;
    return Material(
      color: cellColor,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Row(
            children: [
              BangumiAvatar(imageUrl: imageUrl, radius: 21),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: palette.secondaryLabel,
                        ),
                      ),
                    if (role.isNotEmpty)
                      Text(
                        role,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          fontWeight:
                              roleAccent ? FontWeight.w600 : FontWeight.w400,
                          color: roleAccent
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
