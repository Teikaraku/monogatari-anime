import 'package:flutter/material.dart';

class RuleCard extends StatelessWidget {
  const RuleCard({
    super.key,
    required this.title,
    this.tags = const [],
    this.caption,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.installed = false,
  });

  final String title;
  final List<Widget> tags;
  final String? caption;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool installed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // Keep menu focus from activating the enclosing InkWell's highlight.
    final actions = trailing == null
        ? null
        : Focus(
            parentNode: Focus.maybeOf(context, scopeOk: true),
            canRequestFocus: false,
            skipTraversal: true,
            child: trailing!,
          );
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        selected: selected,
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeInOutCubicEmphasized,
          decoration: BoxDecoration(
            color: selected
                ? Color.alphaBlend(colors.primary.withValues(alpha: 0.1),
                    colors.surfaceContainer)
                : colors.surfaceContainer,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? colors.primary.withValues(alpha: 0.6)
                  : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(12.5),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
                child: LayoutBuilder(builder: (context, constraints) {
                  final stacked = constraints.maxWidth < 300 ||
                      MediaQuery.textScalerOf(context).scale(14) > 20;
                  final identity = Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedContainer(
                        duration: duration,
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: installed && !selected
                              ? const Color(0xFF34C759)
                              : colors.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          selected
                              ? Icons.check_rounded
                              : Icons.extension_rounded,
                          size: 26,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title,
                                style: text.titleMedium?.copyWith(
                                    fontSize: 16, fontWeight: FontWeight.w600),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                            if (subtitle != null && subtitle!.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(subtitle!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodySmall?.copyWith(
                                      fontSize: 12,
                                      color: colors.onSurfaceVariant)),
                            ],
                            if (tags.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(spacing: 6, runSpacing: 6, children: tags),
                            ],
                            if (caption != null) ...[
                              const SizedBox(height: 6),
                              Text(caption!,
                                  style: text.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant)),
                            ],
                          ],
                        ),
                      ),
                    ],
                  );
                  if (stacked) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        identity,
                        if (actions != null) ...[
                          const SizedBox(height: 8),
                          Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: actions),
                        ],
                      ],
                    );
                  }
                  return Row(children: [
                    Expanded(child: identity),
                    if (actions != null) ...[
                      const SizedBox(width: 12),
                      actions
                    ],
                  ]);
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RuleTag extends StatelessWidget {
  const RuleTag({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: foreground, fontWeight: FontWeight.w600)),
      );
}
