import 'package:flutter/material.dart';
import 'package:kazumi/utils/theme.dart';

const EdgeInsets materialBottomSheetContentPadding =
    EdgeInsets.fromLTRB(16, 0, 16, 20);

const EdgeInsets materialBottomSheetTabsPadding =
    EdgeInsets.fromLTRB(16, 0, 16, 12);

/// Title row of a sheet, as in the option sheets of the Monogatari apps: a
/// semibold title with an optional caption and a round grey close button.
class MaterialBottomSheetHeader extends StatelessWidget {
  const MaterialBottomSheetHeader({
    super.key,
    required this.title,
    this.description,
    this.leading,
    this.onClose,
    this.trailing,
    this.compact = false,
  });

  final String title;
  final String? description;
  final Widget? leading;
  final VoidCallback? onClose;
  final Widget? trailing;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 12, compact ? 6 : 12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 19,
                        height: 1.3,
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (description != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing!,
            ] else if (onClose != null) ...[
              const SizedBox(width: 12),
              SheetCloseButton(onPressed: onClose!),
            ],
          ],
        ),
      ),
    );
  }
}

/// The small round close button in the corner of a sheet.
class SheetCloseButton extends StatelessWidget {
  const SheetCloseButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '关闭',
      child: Material(
        color: MonoPalette.of(context).sheetGroup,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 30,
            child: Icon(Icons.close_rounded,
                size: 17, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}
