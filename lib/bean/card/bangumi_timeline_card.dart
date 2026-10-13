import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/utils/theme.dart';

/// The broadcast line of a timetable card.
class TimelineAirtime {
  const TimelineAirtime({required this.time, this.premiere});

  /// "20:30", or "周五 00:30" when it falls on another local day; empty in
  /// the timeline, whose rail carries the time.
  final String time;

  /// "10月15日开播" for shows that have not started yet.
  final String? premiere;
}

class BangumiTimelineCard extends StatelessWidget {
  const BangumiTimelineCard({
    super.key,
    required this.bangumiItem,
    required this.showRating,
    required this.onTap,
    this.isWatching = false,
    this.compact = false,
    this.airtime,
  });

  final BangumiItem bangumiItem;
  final bool showRating;
  final bool isWatching;
  final bool compact;
  final TimelineAirtime? airtime;
  final VoidCallback onTap;

  static final _episodePattern =
      RegExp(r'^\s*([1-9]\d*)\s*[话話集](?=\s*(?:[/／]|$))');

  static const _contentPadding = 10.0;
  static const _cornerRadius = 14.0;
  static const _titleFontSize = 16.0;
  static const _titleLineHeight = 1.35;
  static const _labelFontSize = 12.0;
  static const _labelLineHeight = 4 / 3;
  static const _metadataGap = 8.0;
  static const _footerGap = 12.0;
  static const _ratingIconSize = 16.0;
  static const _ratingPadding = EdgeInsets.symmetric(vertical: 2);
  static const _airtimeFontSize = 14.0;
  static const _airtimeLineHeight = 1.3;
  static const _airtimeGap = 4.0;

  // Shared by the grid and card to keep their text-scaled heights in sync.
  static double heightFor(TextScaler scaler,
      {bool compact = false, bool withAirtime = false}) {
    final titleHeight = scaler.scale(_titleFontSize) * _titleLineHeight * 2;
    final labelHeight = scaler.scale(_labelFontSize) * _labelLineHeight;
    // Plus a little slack: CJK fallback fonts render taller than their size.
    final airtimeHeight = withAirtime
        ? scaler.scale(_airtimeFontSize) * _airtimeLineHeight + _airtimeGap + 6
        : 0.0;
    final footerHeight =
        math.max(_ratingIconSize, labelHeight) + _ratingPadding.vertical;
    final contentHeight = math.max(
      compact ? 120.0 : 136.0,
      airtimeHeight +
          titleHeight +
          _metadataGap +
          labelHeight +
          _footerGap +
          footerHeight,
    );
    return _contentPadding * 2 + contentHeight;
  }

  String _supportingText(String title) {
    // Calendar entries expose episode counts through info.
    final episodes = _episodePattern.firstMatch(bangumiItem.info);
    final tags = bangumiItem.metaTags.isNotEmpty
        ? bangumiItem.metaTags
        : bangumiItem.tags.map((tag) => tag.name);
    final metadata = <String>[
      if (episodes != null) '${episodes.group(1)} 话',
      ...tags
          .map((name) => name.trim())
          .where((name) => name.isNotEmpty)
          .toSet(),
    ];
    if (metadata.isNotEmpty) return metadata.take(3).join(' · ');
    final originalName = bangumiItem.name.trim();
    return originalName != title ? originalName : '';
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: Theme.of(context).colorScheme.surfaceContainer,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(_cornerRadius)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: heightFor(MediaQuery.textScalerOf(context),
                compact: compact, withAirtime: airtime != null),
            child: Padding(
              padding: const EdgeInsets.all(_contentPadding),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildCover(context),
                  SizedBox(width: compact ? 12 : 16),
                  Expanded(child: _buildDetails(context)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetails(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final translatedName = bangumiItem.nameCn.trim();
    final title =
        translatedName.isNotEmpty ? translatedName : bangumiItem.name.trim();
    final supportingText = _supportingText(title);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (airtime != null) ...[
          _buildAirtime(context, airtime!),
          const SizedBox(height: _airtimeGap),
        ],
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            color: colors.onSurface,
            fontSize: _titleFontSize,
            fontWeight: FontWeight.w600,
            height: _titleLineHeight,
          ),
        ),
        if (supportingText.isNotEmpty) ...[
          const SizedBox(height: _metadataGap),
          Text(
            supportingText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.primary,
              fontSize: _labelFontSize,
              height: _labelLineHeight,
            ),
          ),
        ],
        if (showRating || isWatching) ...[
          const Spacer(),
          const SizedBox(height: _footerGap),
          Row(
            children: [
              if (showRating)
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _buildRating(context),
                  ),
                )
              else
                const Spacer(),
              if (isWatching) ...[
                if (showRating) const SizedBox(width: 8),
                Tooltip(
                  message: '正在追',
                  child: Icon(Icons.bookmark_rounded,
                      size: 20, color: colors.primary),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildAirtime(BuildContext context, TimelineAirtime airtime) {
    final colors = Theme.of(context).colorScheme;
    final palette = MonoPalette.of(context);
    final hasTime = airtime.time.isNotEmpty;
    return Row(
      children: [
        if (hasTime)
          Text(
            airtime.time,
            maxLines: 1,
            style: TextStyle(
              fontSize: _airtimeFontSize,
              height: _airtimeLineHeight,
              fontWeight: FontWeight.w700,
              color: colors.primary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        if (airtime.premiere != null) ...[
          if (hasTime) const SizedBox(width: 6),
          Flexible(
            child: Text(
              airtime.premiere!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _labelFontSize,
                height: _airtimeLineHeight,
                color: palette.secondaryLabel,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCover(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final imageUrl = bangumiItem.images['large'] ?? '';
    return ExcludeSemantics(
      child: SizedBox(
        width: compact ? 80 : 88,
        child: LayoutBuilder(
          builder: (context, constraints) => Hero(
            tag: bangumiItem.id,
            transitionOnUserGestures: true,
            child: ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(8)),
              child: imageUrl.isEmpty
                  ? ColoredBox(
                      color: colors.surfaceContainerHighest,
                      child: Center(
                        child: Icon(Icons.movie_outlined,
                            color: colors.onSurfaceVariant),
                      ),
                    )
                  : NetworkImgLayer(
                      src: imageUrl,
                      width: constraints.maxWidth,
                      height: constraints.maxHeight,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRating(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final labelStyle = theme.textTheme.labelMedium?.copyWith(
      fontSize: _labelFontSize,
      height: _labelLineHeight,
    );
    if (bangumiItem.ratingScore <= 0) {
      return Text('暂无评分',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: labelStyle?.copyWith(color: colors.onSurfaceVariant));
    }
    final score = bangumiItem.ratingScore.toStringAsFixed(1);
    return Semantics(
      label: '评分 $score',
      excludeSemantics: true,
      child: Padding(
        padding: _ratingPadding,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star_rounded,
                size: _ratingIconSize,
                color: colors.primary.withValues(alpha: 0.85)),
            const SizedBox(width: 3),
            Flexible(
              child: Text(score,
                  maxLines: 1,
                  style: labelStyle?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
            ),
          ],
        ),
      ),
    );
  }
}
