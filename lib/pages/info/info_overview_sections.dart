import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/modules/bangumi/airing_summary.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_relation.dart';
import 'package:kazumi/modules/bangumi/bangumi_subject_detail.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/utils/theme.dart';

/// Background of the inset cards on the detail page: the secondary grouped
/// background, so cards read on both the white and the black page.
Color infoCardColor(BuildContext context) {
  final palette = MonoPalette.of(context);
  return Theme.of(context).brightness == Brightness.dark
      ? palette.groupedCell
      : palette.groupedBackground;
}

/// Section title of the detail page, with an optional trailing action.
class InfoSectionTitle extends StatelessWidget {
  const InfoSectionTitle(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Semantics(
      header: true,
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleLarge
            ?.copyWith(fontSize: 20, fontWeight: FontWeight.w700),
      ),
    );
    if (trailing == null) return text;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [Expanded(child: text), trailing!],
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: infoCardColor(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: padding ?? const EdgeInsets.all(16),
        child: child,
      ),
    );
  }
}

/// A one-line failure notice with a retry button, for sections that sit
/// between other content.
class InfoInlineRetry extends StatelessWidget {
  const InfoInlineRetry({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _InfoCard(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded,
              size: 18, color: MonoPalette.of(context).secondaryLabel),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Episodes and airing progress

const _weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];

String _twoDigits(num n) => n.toString().padLeft(2, '0');

String _episodeNumber(num n) =>
    n == n.roundToDouble() ? _twoDigits(n.toInt()) : n.toString();

String _monthDay(DateTime day, DateTime today) => day.year == today.year
    ? '${day.month}月${day.day}日'
    : '${day.year}年${day.month}月${day.day}日';

String _fullDate(DateTime day) => '${day.year}年${day.month}月${day.day}日';

String _dotDate(DateTime day) =>
    '${day.year}.${_twoDigits(day.month)}.${_twoDigits(day.day)}';

/// "00:23:45" → "24 分钟"; other formats are shown as Bangumi wrote them.
String? _durationLabel(String raw) {
  if (raw.isEmpty) return null;
  final parts = raw.split(':').map(int.tryParse).toList();
  if (parts.length < 2 || parts.any((part) => part == null)) return raw;
  final seconds = parts.fold<int>(0, (sum, part) => sum * 60 + part!);
  if (seconds <= 0) return null;
  final minutes = math.max(1, (seconds / 60).round());
  if (minutes < 60) return '$minutes 分钟';
  final rest = minutes % 60;
  return rest == 0 ? '${minutes ~/ 60} 小时' : '${minutes ~/ 60} 小时 $rest 分钟';
}

/// Airing progress of the detail page: the shared summary plus the weekday.
class _EpisodeProgress {
  _EpisodeProgress._(this.summary, this.weekday);

  factory _EpisodeProgress.from(
    List<EpisodeInfo> source,
    BangumiSubjectDetail? detail,
    DateTime today,
  ) {
    final summary = AiringSummary.of(source,
        plannedTotal: detail?.totalEpisodes ?? 0, today: today);
    var weekday = detail?.airWeekday ?? 0;
    if (weekday < 1 || weekday > 7) {
      final firstDay = summary.episodes
          .map((e) => e.airDay)
          .firstWhere((day) => day != null, orElse: () => null);
      weekday = firstDay?.weekday ?? 0;
    }
    return _EpisodeProgress._(summary, weekday);
  }

  final AiringSummary summary;
  final int weekday;

  List<EpisodeInfo> get episodes => summary.episodes;
  int get total => summary.total;
  AiringState get state => summary.state;
  int get airedCount => summary.airedCount;
  EpisodeInfo? get latest => summary.latest;
  EpisodeInfo? get next => summary.next;

  /// The episode the strip should start at: the newest aired one, else the next.
  int get focusIndex {
    final focus = latest ?? next;
    return focus == null ? 0 : math.max(0, episodes.indexOf(focus));
  }
}

/// Whether a subject is worth an episode section: series, not single films.
bool infoHasEpisodeSection(
        List<EpisodeInfo>? episodes, BangumiSubjectDetail? detail) =>
    episodes == null
        ? (detail?.totalEpisodes ?? 2) > 1
        : episodes.length > 1 || (detail?.totalEpisodes ?? 0) > 1;

class InfoEpisodeSection extends StatelessWidget {
  const InfoEpisodeSection({
    super.key,
    required this.episodes,
    required this.failed,
    required this.onRetry,
    required this.detail,
  });

  /// Null while loading.
  final List<EpisodeInfo>? episodes;
  final bool failed;
  final VoidCallback onRetry;
  final BangumiSubjectDetail? detail;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (failed) {
      body = InfoInlineRetry(message: '章节加载失败', onRetry: onRetry);
    } else if (episodes == null) {
      body = const _EpisodeSectionBone();
    } else {
      final today = DateUtils.dateOnly(DateTime.now());
      final progress = _EpisodeProgress.from(episodes!, detail, today);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ProgressCard(progress: progress, today: today),
          if (progress.episodes.length > 1) ...[
            const SizedBox(height: 12),
            _EpisodeStrip(progress: progress, today: today),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const InfoSectionTitle('章节'),
        const SizedBox(height: 10),
        body,
      ],
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.progress, required this.today});

  final _EpisodeProgress progress;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = MonoPalette.of(context);
    final latest = progress.latest;
    final next = progress.next;
    final firstDay = progress.episodes
        .map((e) => e.airDay)
        .firstWhere((day) => day != null, orElse: () => null);
    final lastDay = progress.episodes.reversed
        .map((e) => e.airDay)
        .firstWhere((day) => day != null, orElse: () => null);

    final (String? status, String headline) = switch (progress.state) {
      AiringState.airing => (
          '连载中',
          '已更新至第 ${latest!.displayNumber} 话'
        ),
      AiringState.finished => ('已完结', '全 ${progress.total} 话'),
      AiringState.upcoming => (
          '未开播',
          firstDay == null ? '即将开播' : '${_monthDay(firstDay, today)} 开播'
        ),
      AiringState.unknown => (null, '共 ${progress.total} 话'),
    };

    final details = <String>[
      if (progress.state == AiringState.airing ||
          progress.state == AiringState.upcoming)
        '共 ${progress.total} 话',
      if ((progress.state == AiringState.airing ||
              progress.state == AiringState.upcoming) &&
          progress.weekday >= 1 &&
          progress.weekday <= 7)
        '每周${_weekdayNames[progress.weekday - 1]}更新',
      if (progress.state == AiringState.finished &&
          firstDay != null &&
          lastDay != null)
        firstDay == lastDay
            ? _dotDate(firstDay)
            : '${_dotDate(firstDay)} – ${_dotDate(lastDay)}',
    ];

    final showBar = progress.state == AiringState.airing ||
        progress.state == AiringState.finished;
    final ratio = progress.state == AiringState.finished
        ? 1.0
        : progress.total == 0
            ? 0.0
            : (progress.airedCount / progress.total).clamp(0.0, 1.0);

    return _InfoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (status != null) ...[
                _StatusPill(
                  label: status,
                  active: progress.state != AiringState.finished,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  headline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w600, height: 1.3),
                ),
              ),
              if (progress.state == AiringState.airing &&
                  next?.airDay != null) ...[
                const SizedBox(width: 8),
                Text(
                  '下一话 ${_monthDay(next!.airDay!, today)}',
                  style: TextStyle(fontSize: 13, color: colors.primary),
                ),
              ],
            ],
          ),
          if (details.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              details.join(' · '),
              style: TextStyle(fontSize: 13, color: palette.secondaryLabel),
            ),
          ],
          if (showBar) ...[
            const SizedBox(height: 12),
            Container(
              height: 6,
              decoration: BoxDecoration(
                color: palette.hairline.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(3),
              ),
              alignment: Alignment.centerLeft,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: ratio),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => FractionallySizedBox(
                  widthFactor: value,
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: progress.state == AiringState.finished
                          ? palette.success
                          : colors.primary,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? Theme.of(context).colorScheme.primary
        : MonoPalette.of(context).success;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: color),
        ),
      ),
    );
  }
}

class _EpisodeStrip extends StatefulWidget {
  const _EpisodeStrip({required this.progress, required this.today});

  final _EpisodeProgress progress;
  final DateTime today;

  @override
  State<_EpisodeStrip> createState() => _EpisodeStripState();
}

class _EpisodeStripState extends State<_EpisodeStrip> {
  static const double _tileWidth = 124;
  static const double _gap = 10;

  late final ScrollController _controller = ScrollController(
    initialScrollOffset:
        math.max(0, widget.progress.focusIndex - 1) * (_tileWidth + _gap),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final episodes = widget.progress.episodes;
    final textScaler =
        MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2);
    return SizedBox(
      height: textScaler.scale(96),
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: ListView.separated(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          itemCount: episodes.length,
          separatorBuilder: (_, _) => const SizedBox(width: _gap),
          itemBuilder: (context, index) {
            final episode = episodes[index];
            final day = episode.airDay;
            return _EpisodeTile(
              episode: episode,
              width: _tileWidth,
              today: widget.today,
              isLatest: identical(episode, widget.progress.latest),
              upcoming: day != null && day.isAfter(widget.today),
            );
          },
        ),
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.episode,
    required this.width,
    required this.today,
    required this.isLatest,
    required this.upcoming,
  });

  final EpisodeInfo episode;
  final double width;
  final DateTime today;
  final bool isLatest;
  final bool upcoming;

  bool get _hasDetails =>
      episode.nameCn.isNotEmpty ||
      episode.name.isNotEmpty ||
      episode.summary.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = MonoPalette.of(context);
    final title = episode.nameCn.isNotEmpty ? episode.nameCn : episode.name;
    final day = episode.airDay;
    return Opacity(
      opacity: upcoming ? 0.5 : 1,
      child: Material(
        color: infoCardColor(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: isLatest
              ? BorderSide(color: colors.primary.withValues(alpha: 0.7))
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _hasDetails ? () => _showEpisodeSheet(context) : null,
          child: SizedBox(
            width: width,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _episodeNumber(episode.displayNumber),
                    style: TextStyle(
                      fontSize: 18,
                      height: 1.1,
                      fontWeight: FontWeight.w700,
                      color: isLatest ? colors.primary : colors.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13, height: 1.3, color: colors.onSurface),
                    ),
                  ),
                  if (day != null)
                    Text(
                      _monthDay(day, today),
                      maxLines: 1,
                      style:
                          TextStyle(fontSize: 12, color: palette.secondaryLabel),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showEpisodeSheet(BuildContext context) {
    final day = episode.airDay;
    final duration = _durationLabel(episode.duration);
    final facts = [
      if (day != null) _fullDate(day),
      ?duration,
    ];
    showAdaptiveBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final palette = MonoPalette.of(sheetContext);
        final hasCnTitle = episode.nameCn.isNotEmpty;
        final showOriginal =
            episode.name.isNotEmpty && episode.name != episode.nameCn;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MaterialBottomSheetHeader(
              title: '第 ${_episodeNumber(episode.displayNumber)} 话',
              description: facts.isEmpty ? null : facts.join(' · '),
              onClose: () => Navigator.of(sheetContext).pop(),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (hasCnTitle)
                        Text(episode.nameCn,
                            style: theme.textTheme.titleMedium?.copyWith(
                                fontSize: 17, fontWeight: FontWeight.w600)),
                      if (showOriginal) ...[
                        if (hasCnTitle) const SizedBox(height: 2),
                        Text(
                          episode.name,
                          style: TextStyle(
                            fontSize: hasCnTitle ? 14 : 17,
                            fontWeight:
                                hasCnTitle ? FontWeight.w400 : FontWeight.w600,
                            color: hasCnTitle
                                ? palette.secondaryLabel
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ],
                      if (episode.summary.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Text(
                          episode.summary,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.55,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _EpisodeSectionBone extends StatelessWidget {
  const _EpisodeSectionBone();

  @override
  Widget build(BuildContext context) {
    return Skeletonizer.zone(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Bone(height: 92, uniRadius: 16),
          const SizedBox(height: 12),
          SizedBox(
            height: 96,
            // Clipped like the real strip, which also runs off the edge.
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: Row(
                children: [
                  for (var i = 0; i < 4; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    const Bone(width: 124, height: 96, uniRadius: 14),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Rating distribution

const _ratingLabels = [
  '不忍直视',
  '很差',
  '差',
  '较差',
  '不过不失',
  '还行',
  '推荐',
  '力荐',
  '神作',
  '超神作',
];

bool infoHasRatingDistribution(BangumiItem item) =>
    item.votes > 0 &&
    item.votesCount.length == 10 &&
    item.votesCount.any((count) => count > 0);

class InfoRatingSection extends StatefulWidget {
  const InfoRatingSection({super.key, required this.bangumiItem});

  final BangumiItem bangumiItem;

  @override
  State<InfoRatingSection> createState() => _InfoRatingSectionState();
}

class _InfoRatingSectionState extends State<InfoRatingSection> {
  static const double _chartHeight = 120;
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final item = widget.bangumiItem;
    final colors = Theme.of(context).colorScheme;
    final palette = MonoPalette.of(context);
    final counts = item.votesCount;
    final totalVotes = counts.fold<int>(0, (sum, count) => sum + count);
    final maxCount = counts.reduce(math.max);
    final mode = counts.indexOf(maxCount);
    final selected = _selected ?? mode;

    final mean = List.generate(10, (i) => (i + 1) * counts[i])
            .fold<int>(0, (sum, value) => sum + value) /
        totalVotes;
    final variance = List.generate(
          10,
          (i) => counts[i] * math.pow(i + 1 - mean, 2),
        ).fold<double>(0, (sum, value) => sum + value) /
        totalVotes;
    final deviation = math.sqrt(variance);
    final score = item.ratingScore;
    final labelIndex = score.round().clamp(1, 10) - 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const InfoSectionTitle('评分'),
        const SizedBox(height: 10),
        _InfoCard(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    score.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 34,
                      height: 1.05,
                      fontWeight: FontWeight.w700,
                      color: colors.primary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (score > 0) ...[
                              _StatusPill(
                                  label: _ratingLabels[labelIndex], active: true),
                              const SizedBox(width: 8),
                            ],
                            RatingBarIndicator(
                              itemCount: 5,
                              rating: score / 2,
                              itemSize: 15,
                              unratedColor:
                                  colors.primary.withValues(alpha: 0.18),
                              itemBuilder: (context, _) => Icon(
                                Icons.star_rounded,
                                color: colors.primary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${item.votes} 人评分 · 标准差 ${deviation.toStringAsFixed(2)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13, color: palette.secondaryLabel),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 750),
                curve: Curves.easeOutCubic,
                builder: (context, grow, _) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < 10; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        Expanded(
                          child: _RatingBar(
                            score: i + 1,
                            ratio: maxCount == 0 ? 0 : counts[i] / maxCount,
                            share: totalVotes == 0 ? 0 : counts[i] / totalVotes,
                            grow: grow,
                            height: _chartHeight,
                            selected: i == selected,
                            onTap: () => setState(() => _selected = i),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: Text(
                    '${selected + 1} 分 · ${counts[selected]} 人',
                    key: ValueKey(selected),
                    style: TextStyle(fontSize: 12, color: palette.secondaryLabel),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RatingBar extends StatelessWidget {
  const _RatingBar({
    required this.score,
    required this.ratio,
    required this.share,
    required this.grow,
    required this.height,
    required this.selected,
    required this.onTap,
  });

  final int score;
  final double ratio;
  final double share;
  final double grow;
  final double height;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = MonoPalette.of(context);
    final barHeight = math.max(3.0, height * ratio * grow);
    final color = selected
        ? colors.primary
        : colors.primary.withValues(alpha: 0.18 + 0.32 * ratio);
    final percent = share * 100;
    return Semantics(
      button: true,
      selected: selected,
      label: '$score 分，${(percent).toStringAsFixed(1)}%',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 16,
              child: AnimatedOpacity(
                opacity: selected ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    percent >= 10
                        ? '${percent.round()}%'
                        : '${percent.toStringAsFixed(1)}%',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: colors.primary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: height,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  height: barHeight,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(6)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$score',
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? colors.primary : palette.secondaryLabel,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Related subjects

bool infoHasRelationSection({
  required bool hasLoaded,
  required bool failed,
  required int count,
}) =>
    failed || !hasLoaded || count > 0;

class InfoRelationsSection extends StatelessWidget {
  const InfoRelationsSection({
    super.key,
    required this.relations,
    required this.hasLoaded,
    required this.failed,
    required this.onRetry,
  });

  final List<BangumiRelation> relations;
  final bool hasLoaded;
  final bool failed;
  final VoidCallback onRetry;

  static const double _cardWidth = 108;

  @override
  Widget build(BuildContext context) {
    final textScaler =
        MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.15);
    final Widget body;
    if (failed) {
      body = InfoInlineRetry(message: '关联作品加载失败', onRetry: onRetry);
    } else if (!hasLoaded) {
      body = Skeletonizer.zone(
        child: SizedBox(
          height: 212,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: Row(
              children: [
                for (var i = 0; i < 4; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  const Bone(width: _cardWidth, height: 212, uniRadius: 10),
                ],
              ],
            ),
          ),
        ),
      );
    } else {
      // Poster, gaps, one relation line and two title lines.
      body = SizedBox(
        height: 152 + 8 + textScaler.scale(12 * 1.35 + 13 * 1.3 * 2 + 2),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: relations.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) => _RelationPoster(
              relation: relations[index],
              width: _cardWidth,
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const InfoSectionTitle('关联'),
        const SizedBox(height: 10),
        body,
      ],
    );
  }
}

class _RelationPoster extends StatelessWidget {
  const _RelationPoster({required this.relation, required this.width});

  final BangumiRelation relation;
  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final item = relation.toBangumiItem();
    final title = item.nameCn.isEmpty ? item.name.trim() : item.nameCn.trim();
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => context.pushNamed('/info/', arguments: item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            NetworkImgLayer(
              src: item.images['large'] ?? '',
              width: width,
              height: 152,
              borderRadius: BorderRadius.circular(10),
            ),
            const SizedBox(height: 6),
            Text(
              relation.relation,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: colors.primary,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, height: 1.3, color: colors.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Basic facts (infobox)

/// Facts shown before "展开全部", in this order when present.
const _primaryFactKeys = [
  '别名',
  '话数',
  '放送开始',
  '放送星期',
  '播放结束',
  '上映年度',
  '片长',
  '动画制作',
  '原作',
  '导演',
  '系列构成',
  '脚本',
  '人物设定',
  '音乐',
  '播放电视台',
  '其他电视台',
  '在线播放平台',
  '官方网站',
  '链接',
];

/// The title already carries the Chinese name.
const _hiddenFactKeys = {'中文名'};

List<BangumiInfoboxField> _visibleFacts(BangumiSubjectDetail? detail) =>
    detail == null
        ? const []
        : detail.infobox
            .where((field) => !_hiddenFactKeys.contains(field.key))
            .toList();

bool infoHasFactsSection(BangumiSubjectDetail? detail, bool loading) =>
    loading || _visibleFacts(detail).isNotEmpty;

class InfoFactsSection extends StatefulWidget {
  const InfoFactsSection({
    super.key,
    required this.detail,
    required this.loading,
  });

  final BangumiSubjectDetail? detail;
  final bool loading;

  @override
  State<InfoFactsSection> createState() => _InfoFactsSectionState();
}

class _InfoFactsSectionState extends State<InfoFactsSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.loading && widget.detail == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const InfoSectionTitle('基本资料'),
          const SizedBox(height: 10),
          Skeletonizer.zone(child: Bone(height: 220, uniRadius: 16)),
        ],
      );
    }

    final facts = _visibleFacts(widget.detail);
    final byKey = {for (final field in facts) field.key: field};
    final primary = [
      for (final key in _primaryFactKeys)
        if (byKey[key] != null) byKey[key]!,
    ];
    // Subjects without the usual keys still show their first fields.
    final head = primary.isNotEmpty ? primary : facts.take(8).toList();
    final rest = facts.where((field) => !head.contains(field)).toList();
    final shown = _expanded ? [...head, ...rest] : head;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InfoSectionTitle(
          '基本资料',
          trailing: rest.isEmpty
              ? null
              : TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(_expanded ? '收起' : '展开全部'),
                ),
        ),
        const SizedBox(height: 10),
        SelectionArea(
          child: _InfoCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(start: 16),
                      child: Divider(
                        height: 0.5,
                        thickness: 0.5,
                        color: MonoPalette.of(context).hairline,
                      ),
                    ),
                  _FactRow(field: shown[i]),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.field});

  final BangumiInfoboxField field;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = MonoPalette.of(context);
    final valueStyle =
        TextStyle(fontSize: 14, height: 1.45, color: colors.onSurface);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              field.key,
              style: TextStyle(
                  fontSize: 14, height: 1.45, color: palette.secondaryLabel),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final value in field.values)
                  if (value.link case final link?)
                    _FactLink(label: value.label, uri: link)
                  else
                    Text.rich(
                      TextSpan(children: [
                        if (value.label.isNotEmpty)
                          TextSpan(
                            text: '${value.label}  ',
                            style: TextStyle(color: palette.secondaryLabel),
                          ),
                        TextSpan(text: value.value),
                      ]),
                      style: valueStyle,
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FactLink extends StatelessWidget {
  const _FactLink({required this.label, required this.uri});

  final String label;
  final Uri uri;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final path = uri.path == '/' ? '' : uri.path;
    final text = label.isNotEmpty ? label : '${uri.host}$path';
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => launchUrl(uri, mode: LaunchMode.externalApplication),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: text),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(left: 3),
              child: Icon(Icons.north_east_rounded,
                  size: 13, color: colors.primary),
            ),
          ),
        ]),
        style: TextStyle(fontSize: 14, height: 1.45, color: colors.primary),
      ),
    );
  }
}
