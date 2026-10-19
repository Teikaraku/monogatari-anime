import 'package:flutter/material.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';

/// Shrink-wraps in slivers and scrolls within bounded viewports.
class GeneralEmptyState extends StatelessWidget {
  const GeneralEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.actions = const [],
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final List<Widget> actions;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Center(
      child: SingleChildScrollView(
        primary: false,
        padding: compact
            ? const EdgeInsets.all(16)
            : const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StateIconBadge(
                icon: icon,
                size: compact ? 52 : 86,
                iconSize: compact ? 28 : 36,
                backgroundColor: colorScheme.surfaceContainer,
                foregroundColor: colorScheme.onSurfaceVariant,
              ),
              SizedBox(height: compact ? 10 : 16),
              Semantics(
                header: true,
                liveRegion: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style:
                      (compact ? textTheme.titleMedium : textTheme.titleLarge)
                          ?.copyWith(
                    fontSize: compact ? 17 : 22,
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (actions.isNotEmpty) ...[
                SizedBox(height: compact ? 16 : 24),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
