import 'package:flutter/material.dart';

import 'package:kazumi/bean/widget/split_list_row.dart';
import 'package:kazumi/utils/theme.dart';

/// Rows of the RSS pages in one inset group, split by hairlines that start
/// at the row text.
class RssGroup extends StatelessWidget {
  const RssGroup({super.key, required this.children, this.dividerIndent = 16});

  final List<Widget> children;
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    final hairline = MonoPalette.of(context).hairline;
    return Material(
      color: monoCellColor(context),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 0.5,
                thickness: 0.5,
                indent: dividerIndent,
                color: hairline,
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// A list row: optional leading, a title with up to two lines below it, and
/// trailing controls.
class RssRow extends StatelessWidget {
  const RssRow({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.detail,
    this.trailing,
    this.onTap,
    this.titleColor,
    this.titleWeight = FontWeight.w400,
    this.titleMaxLines = 2,
    this.subtitleColor,
    this.detailColor,
    this.detailMaxLines = 2,
    this.titleBadge,
    this.selected,
  });

  final String title;
  final Widget? leading;
  final String? subtitle;

  /// A third, quieter line.
  final String? detail;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;
  final FontWeight titleWeight;
  final int titleMaxLines;
  final Color? subtitleColor;
  final Color? detailColor;
  final int detailMaxLines;

  /// Shown right after the title, such as a 新 marker.
  final Widget? titleBadge;
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = MonoPalette.of(context);
    final titleText = Text(
      title,
      maxLines: titleMaxLines,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyLarge?.copyWith(
        fontSize: 16,
        height: 1.3,
        fontWeight: titleWeight,
        color: titleColor ?? theme.colorScheme.onSurface,
      ),
    );
    return Semantics(
      selected: selected,
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              16,
              10,
              trailing == null ? 16 : 8,
              10,
            ),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(child: titleText),
                          if (titleBadge != null) ...[
                            const SizedBox(width: 6),
                            titleBadge!,
                          ],
                        ],
                      ),
                      if (subtitle != null && subtitle!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 13,
                            height: 1.35,
                            color: subtitleColor ?? palette.secondaryLabel,
                          ),
                        ),
                      ],
                      if (detail != null && detail!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          detail!,
                          maxLines: detailMaxLines,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 12,
                            height: 1.35,
                            color: detailColor ?? palette.tertiaryLabel,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 4), trailing!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An accent-coloured action row, such as 添加字幕组.
class RssActionRow extends StatelessWidget {
  const RssActionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = onTap == null
        ? colors.onSurface.withValues(alpha: 0.38)
        : colors.primary;
    return RssRow(
      leading: SizedBox(width: 24, child: Icon(icon, size: 22, color: color)),
      title: label,
      titleColor: color,
      titleMaxLines: 1,
      onTap: onTap,
    );
  }
}

/// The small grey caption above a group.
class RssCaption extends StatelessWidget {
  const RssCaption(this.title, {super.key, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 13,
      height: 1.3,
      color: MonoPalette.of(context).secondaryLabel,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Semantics(header: true, child: Text(title, style: style)),
          ),
          if (trailing != null) Text(trailing!, style: style),
        ],
      ),
    );
  }
}

enum RssBannerTone { progress, error, info }

/// A one-line status above the content: a running operation that can be
/// cancelled, a failure that can be retried, or a notice.
class RssBanner extends StatelessWidget {
  const RssBanner({
    super.key,
    required this.message,
    required this.tone,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final RssBannerTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = MonoPalette.of(context);
    final tint = switch (tone) {
      RssBannerTone.error => colors.error,
      RssBannerTone.progress => colors.primary,
      RssBannerTone.info => palette.secondaryLabel,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Color.alphaBlend(
          tint.withValues(alpha: 0.10),
          monoCellColor(context),
        ),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            14,
            6,
            actionLabel == null ? 14 : 4,
            6,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: tone == RssBannerTone.progress
                      ? Padding(
                          padding: const EdgeInsets.all(2),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: tint,
                          ),
                        )
                      : Icon(
                          tone == RssBannerTone.error
                              ? Icons.error_outline_rounded
                              : Icons.info_outline_rounded,
                          size: 20,
                          color: tint,
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.35,
                      color: tone == RssBannerTone.error
                          ? colors.error
                          : colors.onSurface,
                    ),
                  ),
                ),
                if (actionLabel != null)
                  TextButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The ⋯ button that opens a row's or page's menu.
class RssMoreButton extends StatelessWidget {
  const RssMoreButton({
    super.key,
    required this.onPressed,
    this.tooltip = '更多',
  });

  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    color: MonoPalette.of(context).secondaryLabel,
    icon: const Icon(Icons.more_horiz_rounded),
  );
}

/// 今天 18:20, 10月13日, or 2025年10月13日 for other years.
String rssShortDate(DateTime date, {bool withTime = false, DateTime? now}) {
  final local = date.toLocal();
  final today = now ?? DateTime.now();
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (local.year == today.year &&
      local.month == today.month &&
      local.day == today.day) {
    return withTime ? '今天 $time' : '今天';
  }
  final day = local.year == today.year
      ? '${local.month}月${local.day}日'
      : '${local.year}年${local.month}月${local.day}日';
  return withTime ? '$day $time' : day;
}

/// A small 新 marker for releases published since the show was last opened.
class RssNewBadge extends StatelessWidget {
  const RssNewBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '新',
        style: TextStyle(
          fontSize: 11,
          height: 1.3,
          fontWeight: FontWeight.w600,
          color: colors.primary,
        ),
      ),
    );
  }
}
