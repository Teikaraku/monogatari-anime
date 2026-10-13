import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/modules/history/watch_activity.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/utils/theme.dart';

const _weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];

/// 观看统计: totals, a year of viewing as a heatmap, and the episodes of the
/// chosen day.
class WatchStatsPage extends StatefulWidget {
  const WatchStatsPage({super.key, required this.controller});

  final HistoryController controller;

  @override
  State<WatchStatsPage> createState() => _WatchStatsPageState();
}

class _WatchStatsPageState extends State<WatchStatsPage> {
  DateTime? _selected;

  @override
  void initState() {
    super.initState();
    widget.controller.init();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('观看统计'),
      body: Observer(builder: (context) {
        final activity =
            WatchActivity.from(widget.controller.histories.toList());
        final today = WatchActivity.dayOf(DateTime.now());
        final selected = _selected ??
            (activity.countOn(today) > 0
                ? today
                : activity.lastActiveDay ?? today);
        final yearAgo = DateTime(today.year - 1, today.month, today.day + 1);
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Totals(activity: activity, today: today),
                    const SizedBox(height: 24),
                    _SectionTitle(
                      '观看热力图',
                      trailing:
                          '近一年 ${activity.episodesBetween(yearAgo, today)} 集',
                    ),
                    _Card(
                      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
                      child: _Heatmap(
                        activity: activity,
                        today: today,
                        selected: selected,
                        onSelect: (day) => setState(() => _selected = day),
                      ),
                    ),
                    const SizedBox(height: 24),
                    _DayEpisodes(activity: activity, day: selected),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: MonoPalette.of(context).groupedCell,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding ?? const EdgeInsets.all(16),
        child: child,
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = MonoPalette.of(context);
    final style = TextStyle(fontSize: 13, color: palette.secondaryLabel);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title, style: style),
            ),
          ),
          if (trailing != null) Text(trailing!, style: style),
        ],
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.activity, required this.today});

  final WatchActivity activity;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final yearAgo = DateTime(today.year - 1, today.month, today.day + 1);
    final figures = [
      ('${activity.bangumiCount}', '看过番剧'),
      ('${activity.episodeCount}', '观看集数'),
      ('${activity.activeDaysBetween(yearAgo, today)}', '近一年活跃天数'),
      (
        '${activity.currentStreak(today)}',
        '连续观看天数 · 最长 ${activity.longestStreak}'
      ),
    ];
    return _Card(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          for (var row = 0; row < 2; row++) ...[
            if (row > 0)
              Divider(
                height: 0.5,
                thickness: 0.5,
                indent: 16,
                endIndent: 16,
                color: MonoPalette.of(context).hairline,
              ),
            IntrinsicHeight(
              child: Row(
                children: [
                  for (var col = 0; col < 2; col++) ...[
                    if (col > 0)
                      VerticalDivider(
                        width: 0.5,
                        thickness: 0.5,
                        indent: 12,
                        endIndent: 12,
                        color: MonoPalette.of(context).hairline,
                      ),
                    Expanded(
                      child: _Figure(
                        value: figures[row * 2 + col].$1,
                        label: figures[row * 2 + col].$2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 28,
                height: 1.1,
                fontWeight: FontWeight.w700,
                color: colors.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12, color: MonoPalette.of(context).secondaryLabel),
          ),
        ],
      ),
    );
  }
}

/// A year of viewing, one column per week (Monday first), newest at the right.
class _Heatmap extends StatelessWidget {
  const _Heatmap({
    required this.activity,
    required this.today,
    required this.selected,
    required this.onSelect,
  });

  static const int _weeks = 53;
  static const double _cell = 14;
  static const double _gap = 3;
  static const double _monthRow = 18;

  final WatchActivity activity;
  final DateTime today;
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  /// Episodes per day → shade, from none to 7 or more.
  static int _level(int count) => switch (count) {
        0 => 0,
        1 => 1,
        <= 3 => 2,
        <= 6 => 3,
        _ => 4,
      };

  static Color colorFor(BuildContext context, int level) {
    final primary = Theme.of(context).colorScheme.primary;
    return switch (level) {
      0 => MonoPalette.of(context).fill,
      1 => primary.withValues(alpha: 0.28),
      2 => primary.withValues(alpha: 0.5),
      3 => primary.withValues(alpha: 0.75),
      _ => primary,
    };
  }

  @override
  Widget build(BuildContext context) {
    final palette = MonoPalette.of(context);
    final colors = Theme.of(context).colorScheme;
    final firstMonday = DateTime(
        today.year, today.month, today.day - (today.weekday - 1) - 7 * (_weeks - 1));
    final labelStyle = TextStyle(fontSize: 10, color: palette.secondaryLabel);
    const step = _cell + _gap;

    final months = <Widget>[];
    for (var week = 0; week < _weeks; week++) {
      final monday = DateTime(
          firstMonday.year, firstMonday.month, firstMonday.day + week * 7);
      final previous = DateTime(monday.year, monday.month, monday.day - 7);
      if (week == 0 || monday.month != previous.month) {
        // Skip a label squeezed against the first one.
        if (week > 0 && week < 3) continue;
        months.add(Positioned(
          left: week * step,
          top: 0,
          child: Text('${monday.month}月', style: labelStyle),
        ));
      }
    }

    final grid = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _weeks * step,
          height: _monthRow,
          child: Stack(clipBehavior: Clip.none, children: months),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var week = 0; week < _weeks; week++)
              Padding(
                padding: const EdgeInsets.only(right: _gap),
                child: Column(
                  children: [
                    for (var weekday = 0; weekday < 7; weekday++)
                      _cellFor(
                        context,
                        DateTime(firstMonday.year, firstMonday.month,
                            firstMonday.day + week * 7 + weekday),
                        colors,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: _monthRow),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var weekday = 0; weekday < 7; weekday++)
                    SizedBox(
                      width: 18,
                      height: step,
                      child: weekday.isEven
                          ? Text(_weekdayNames[weekday], style: labelStyle)
                          : null,
                    ),
                ],
              ),
            ),
            Expanded(
              // Reversed, so the current week shows first.
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: grid,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text('少', style: labelStyle),
            const SizedBox(width: 4),
            for (var level = 0; level <= 4; level++)
              Padding(
                padding: const EdgeInsets.only(right: _gap),
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: colorFor(context, level),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            const SizedBox(width: 1),
            Text('多', style: labelStyle),
          ],
        ),
      ],
    );
  }

  Widget _cellFor(BuildContext context, DateTime day, ColorScheme colors) {
    const box = SizedBox(width: _cell, height: _cell + _gap);
    if (day.isAfter(today)) return box;
    final count = activity.countOn(day);
    final isSelected = day == selected;
    return Semantics(
      button: true,
      selected: isSelected,
      label: '${day.month}月${day.day}日，$count 集',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelect(day),
        child: Padding(
          padding: const EdgeInsets.only(bottom: _gap),
          child: Container(
            width: _cell,
            height: _cell,
            decoration: BoxDecoration(
              color: colorFor(context, _level(count)),
              borderRadius: BorderRadius.circular(3),
              border: isSelected
                  ? Border.all(color: colors.onSurface, width: 1.5)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _DayEpisodes extends StatelessWidget {
  const _DayEpisodes({required this.activity, required this.day});

  final WatchActivity activity;
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final episodes = activity.on(day);
    final palette = MonoPalette.of(context);
    final colors = Theme.of(context).colorScheme;
    final today = WatchActivity.dayOf(DateTime.now());
    final label = day == today
        ? '今天'
        : '${day.year == today.year ? '' : '${day.year}年'}'
            '${day.month}月${day.day}日 周${_weekdayNames[day.weekday - 1]}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(label,
            trailing: episodes.isEmpty ? null : '${episodes.length} 集'),
        _Card(
          padding: EdgeInsets.zero,
          child: episodes.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '这一天没有观看记录',
                    style:
                        TextStyle(fontSize: 14, color: palette.secondaryLabel),
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < episodes.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 0.5,
                          thickness: 0.5,
                          indent: 72,
                          color: palette.hairline,
                        ),
                      _EpisodeRow(episode: episodes[i], colors: colors),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({required this.episode, required this.colors});

  final WatchedEpisode episode;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    final item = episode.bangumiItem;
    final title = item.nameCn.isNotEmpty ? item.nameCn : item.name;
    final time = episode.watchedAt;
    final palette = MonoPalette.of(context);
    return InkWell(
      onTap: () => context.pushNamed('/info/', arguments: item),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            NetworkImgLayer(
              src: item.images['large'] ?? '',
              width: 40,
              height: 56,
              borderRadius: BorderRadius.circular(6),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '第 ${episode.episode} 话',
                    style: TextStyle(fontSize: 13, color: palette.secondaryLabel),
                  ),
                ],
              ),
            ),
            Text(
              '${time.hour.toString().padLeft(2, '0')}:'
              '${time.minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                fontSize: 13,
                color: palette.secondaryLabel,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
