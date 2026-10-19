import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/card/bangumi_timeline_card.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/bean/widget/bangumi_mirror_error_widget.dart';
import 'package:kazumi/bean/widget/content_section.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/bean/widget/mono_chip.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/broadcast_slot.dart';
import 'package:kazumi/pages/timeline/timeline_controller.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/anime_season.dart';
import 'package:kazumi/utils/theme.dart';

part 'timeline_options.dart';
part 'timeline_rail.dart';
part 'timeline_week_selector.dart';

const _weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];

class TimelinePage extends StatefulWidget {
  const TimelinePage({
    super.key,
    required this.controller,
  });

  final TimelineController controller;

  @override
  State<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends State<TimelinePage> {
  TimelineController get _controller => widget.controller;
  late final bool _showRating;

  @override
  void initState() {
    super.initState();
    _showRating = GStorage.getSetting(SettingsKeys.showRating);
    if (_controller.bangumiCalendar.isEmpty) {
      _controller.loadSeason(_controller.selectedDate);
    }
  }

  String _seasonLabel(DateTime date) {
    return '${date.year}年${getSeasonStringByMonth(date.month)}季';
  }

  void _showSeasonBottomSheet(BuildContext context) {
    final now = DateTime.now();
    final years = List.generate(20, (i) => now.year - i);
    showAdaptiveBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      maxHeightFactor: .86,
      builder: (context) => Column(
        children: [
          MaterialBottomSheetHeader(
            title: '放送季度',
            description: '正在查看 ${_seasonLabel(_controller.selectedDate)}',
            onClose: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: ListView.separated(
              padding: materialBottomSheetContentPadding,
              itemCount: years.length,
              separatorBuilder: (_, __) => const SizedBox(height: 24),
              itemBuilder: (context, index) {
                final year = years[index];
                return ContentSection(
                  title: '$year',
                  padding: const EdgeInsets.all(8),
                  child: LayoutBuilder(builder: (context, constraints) {
                    final columns =
                        MediaQuery.textScalerOf(context).scale(14) > 21 ? 2 : 4;
                    return Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final month in [1, 4, 7, 10])
                          SizedBox(
                            width: (constraints.maxWidth - 4 * (columns - 1)) /
                                columns,
                            child: _seasonButton(
                                context, DateTime(year, month), now),
                          ),
                      ],
                    );
                  }),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _seasonButton(BuildContext context, DateTime date, DateTime now) {
    final selected = isSameSeason(_controller.selectedDate, date);
    final colors = Theme.of(context).colorScheme;
    return TextButton(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        backgroundColor:
            selected ? colors.secondaryContainer : Colors.transparent,
        foregroundColor:
            selected ? colors.onSecondaryContainer : colors.onSurface,
      ),
      onPressed: !date.isAfter(now)
          ? () {
              Navigator.of(context).pop();
              _controller.loadSeason(date);
            }
          : null,
      child: Text('${getSeasonStringByMonth(date.month)}季'),
    );
  }

  void _showOptions() {
    showAdaptiveBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      maxHeightFactor: .8,
      compactLandscapeMaxHeightFactor: 1,
      builder: (_) => _TimelineOptionsSheet(controller: _controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 7,
      initialIndex: DateTime.now().weekday - 1,
      animationDuration:
          MediaQuery.disableAnimationsOf(context) ? Duration.zero : null,
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      final narrowPortrait = constraints.maxWidth < 600 &&
          constraints.maxHeight > constraints.maxWidth;
      final sidePadding = constraints.maxWidth < 600 ? 16.0 : 24.0;
      final contentWidth =
          (constraints.maxWidth - sidePadding * 2).clamp(0.0, 1280.0);
      final inset = (constraints.maxWidth - contentWidth) / 2;
      final minCardWidth = scaler.scale(16) > 24 ? 440.0 : 340.0;
      final columns =
          ((contentWidth + 12) / (minCardWidth + 12)).floor().clamp(1, 3);
      return Observer(builder: (context) {
        final loading = _controller.isLoading;
        final failed = _controller.isTimeOut;
        final watchingIds = _controller.loadWatchingBangumiIds();
        final calendar = _controller.filterCalendar(watchingIds);
        final today = DateTime.now();
        final currentSeason = isSameSeason(_controller.selectedDate, today);
        final seasonHeader = narrowPortrait
            ? null
            : _buildSeasonHeader(context,
                loading: loading, compact: constraints.maxHeight < 500);
        final weekHeight = _TimelineWeekSelector.heightFor(scaler) + 16;
        final weekSelector = Padding(
          padding: EdgeInsets.fromLTRB(inset, 0, inset, 16),
          child: _TimelineWeekSelector(
            counts: calendar.map((day) => day.length).toList(),
            todayIndex: currentSeason ? today.weekday - 1 : null,
            isLoading: loading || failed,
          ),
        );
        return Scaffold(
          appBar: SysAppBar(
            needTopOffset: false,
            title: const Text('时间表'),
            contentWidth: (width) => width - inset * 2 + 40,
            actions: [
              IconButton(
                tooltip: '新番速览',
                onPressed: () => context.pushNamed('/season-preview/'),
                icon: const Icon(Icons.style_rounded),
              ),
              if (narrowPortrait)
                _buildSeasonPicker(context, loading: loading, inAppBar: true),
              _TimelineOptionsButton(
                availableWidth: constraints.maxWidth,
                sort: _controller.sort,
                filterCount: _controller.activeFilterCount,
                onPressed: _showOptions,
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: LayoutBuilder(
                builder: (context, viewport) => NestedScrollView(
                      // Keep the outer viewport clamped and unstretched so tabs stay fixed.
                      physics: const ClampingScrollPhysics(),
                      scrollBehavior: ScrollConfiguration.of(context).copyWith(
                        overscroll: false,
                        scrollbars: false,
                      ),
                      headerSliverBuilder: (context, innerBoxIsScrolled) => [
                        if (seasonHeader != null)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(inset, 8, inset, 20),
                              child: seasonHeader,
                            ),
                          ),
                        SliverOverlapAbsorber(
                          handle:
                              NestedScrollView.sliverOverlapAbsorberHandleFor(
                                  context),
                          sliver: SliverPersistentHeader(
                            pinned: true,
                            delegate: _WeekHeaderDelegate(
                              height: weekHeight,
                              color: theme.scaffoldBackgroundColor,
                              child: weekSelector,
                            ),
                          ),
                        ),
                      ],
                      body: loading && calendar.every((day) => day.isEmpty)
                          ? _buildLoading(viewport.maxHeight, weekHeight)
                          : failed
                              ? _TimelineScrollView(
                                  slivers: [
                                    SliverPadding(
                                      padding: const EdgeInsets.all(24),
                                      sliver: SliverToBoxAdapter(
                                        child: BangumiMirrorErrorWidget(
                                          onRetry: () => _controller.loadSeason(
                                              _controller.selectedDate),
                                          onSettingsReturned: () {
                                            if (mounted) setState(() {});
                                          },
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : TabBarView(
                                  children: [
                                    for (var day = 0; day < 7; day++)
                                      _buildDay(
                                        context,
                                        day: day,
                                        items: calendar[day],
                                        watchingIds: watchingIds,
                                        columns: columns,
                                        inset: inset,
                                        compact: narrowPortrait,
                                        currentSeason: currentSeason,
                                      ),
                                  ],
                                ),
                    )),
          ),
        );
      });
    });
  }

  Widget _buildLoading(double viewportHeight, double overlapHeight) {
    return LayoutBuilder(builder: (context, constraints) {
      // Center loading in the full viewport, including the scroll headers.
      final contentHeight =
          (constraints.maxHeight - overlapHeight).clamp(0.0, double.infinity);
      final headerHeight = viewportHeight - contentHeight;
      final bottomInset = headerHeight.clamp(
          0.0, (contentHeight - 48).clamp(0.0, double.infinity));
      return _TimelineScrollView(
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: const Center(child: LoadingIndicator()),
            ),
          ),
        ],
      );
    });
  }

  Widget _buildSeasonPicker(BuildContext context,
      {required bool loading, bool compact = false, bool inAppBar = false}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final label = _seasonLabel(_controller.selectedDate);
    final style = inAppBar
        ? theme.textTheme.bodyLarge?.copyWith(
            fontSize: 15, fontWeight: FontWeight.w500, color: colors.primary)
        : (compact || MediaQuery.textScalerOf(context).scale(16) > 24
                ? theme.textTheme.titleLarge
                : theme.textTheme.headlineSmall)
            ?.copyWith(color: colors.onSurface, fontWeight: FontWeight.w700);
    return Semantics(
      label: '切换放送季度，$label',
      button: true,
      enabled: !loading,
      onTap: loading ? null : () => _showSeasonBottomSheet(context),
      excludeSemantics: true,
      child: Tooltip(
        message: '切换放送季度',
        child: InkWell(
          onTap: loading ? null : () => _showSeasonBottomSheet(context),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: inAppBar
                ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
                : const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(label,
                      maxLines: inAppBar ? 1 : null,
                      overflow: inAppBar ? TextOverflow.ellipsis : null,
                      style: style),
                ),
                SizedBox(width: inAppBar ? 2 : 6),
                Icon(
                  inAppBar
                      ? Icons.unfold_more_rounded
                      : Icons.expand_more_rounded,
                  size: inAppBar ? 18 : 26,
                  color: colors.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSeasonHeader(BuildContext context,
      {required bool loading, required bool compact}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final date = _controller.selectedDate;
    final startMonth = ((date.month - 1) ~/ 3) * 3 + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSeasonPicker(context, loading: loading, compact: compact),
        if (!compact)
          Text(
            loading ? '正在加载放送时间表…' : '$startMonth — ${startMonth + 2} 月 · 每周放送',
            style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 13, color: colors.onSurfaceVariant),
          ),
      ],
    );
  }

  Widget _buildDay(
    BuildContext context, {
    required int day,
    required List<BangumiItem> items,
    required Set<int> watchingIds,
    required int columns,
    required double inset,
    required bool compact,
    required bool currentSeason,
  }) {
    final rawCalendar = _controller.bangumiCalendar;
    final filteredOut = day < rawCalendar.length && rawCalendar[day].isNotEmpty;
    if (items.isEmpty) {
      return _TimelineScrollView(
        key: PageStorageKey('timeline-day-$day'),
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              child: GeneralEmptyState(
                icon: filteredOut
                    ? Icons.filter_alt_off_rounded
                    : Icons.event_available_rounded,
                title: filteredOut ? '没有符合筛选的番剧' : '这一天暂无放送',
                actions: [
                  if (filteredOut)
                    StateActionButton.tonal(
                      onPressed: _controller.clearFilters,
                      text: '清除筛选',
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final airtimes = _controller.airtimes;
    final weekday = day + 1;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isToday = currentSeason && now.weekday == weekday;
    final scaler = MediaQuery.textScalerOf(context);

    String? dayPrefixOf(BroadcastSlot slot) => slot.localWeekday == weekday
        ? null
        : '周${_weekdayNames[slot.localWeekday - 1]}';

    String? premiereOf(BroadcastSlot slot) {
      if (!currentSeason) return null;
      final start = slot.localStart;
      return DateTime(start.year, start.month, start.day).isAfter(today)
          ? '${start.month}月${start.day}日开播'
          : null;
    }

    Widget card(BangumiItem item, TimelineAirtime? airtime) =>
        BangumiTimelineCard(
          key: ValueKey(item.id),
          bangumiItem: item,
          compact: compact,
          showRating: _showRating,
          isWatching: watchingIds.contains(item.id),
          airtime: airtime,
          onTap: () => context.pushNamed('/info/', arguments: item),
        );

    SliverGrid grid(List<BangumiItem> shown, int columns,
        TimelineAirtime? Function(BangumiItem item) airtimeOf) {
      final cardHeight = BangumiTimelineCard.heightFor(scaler,
          compact: compact,
          withAirtime: shown.any((item) => airtimeOf(item) != null));
      return SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          mainAxisExtent: cardHeight,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => card(shown[index], airtimeOf(shown[index])),
          childCount: shown.length,
        ),
      );
    }

    // Other sort orders keep the plain grid, with the time on each card.
    if (_controller.sort != TimelineSort.airTime) {
      TimelineAirtime? airtimeOf(BangumiItem item) {
        final slot = airtimes[item.id];
        if (slot == null) return null;
        final prefix = dayPrefixOf(slot);
        return TimelineAirtime(
          time: prefix == null
              ? slot.localTimeLabel
              : '$prefix ${slot.localTimeLabel}',
          premiere: premiereOf(slot),
        );
      }

      return _TimelineScrollView(
        key: PageStorageKey('timeline-day-$day'),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 0, inset, 24),
            sliver: grid(items, columns, airtimeOf),
          ),
        ],
      );
    }

    // Timeline: items arrive sorted by broadcast time, untimed ones last.
    final groups = <_TimelineGroup>[];
    final untimed = <BangumiItem>[];
    for (final item in items) {
      final slot = airtimes[item.id];
      if (slot == null) {
        untimed.add(item);
        continue;
      }
      final prefix = dayPrefixOf(slot);
      final last = groups.isEmpty ? null : groups.last;
      if (last != null &&
          last.time == slot.localTimeLabel &&
          last.dayPrefix == prefix) {
        last.items.add(item);
      } else {
        groups.add(
            _TimelineGroup(time: slot.localTimeLabel, dayPrefix: prefix)
              ..items.add(item));
      }
    }

    // Today, past times are "已更新" and the first one ahead "即将更新".
    final states = List.filled(groups.length, _NodeState.normal);
    if (isToday) {
      var nextFound = false;
      for (var i = 0; i < groups.length; i++) {
        final group = groups[i];
        if (group.dayPrefix != null) continue;
        final parts = group.time.split(':');
        final at = today.add(Duration(
            hours: int.parse(parts[0]), minutes: int.parse(parts[1])));
        if (!at.isAfter(now)) {
          states[i] = _NodeState.aired;
        } else if (!nextFound) {
          states[i] = _NodeState.next;
          nextFound = true;
        }
      }
    }

    TimelineAirtime? premiereLine(BangumiItem item) {
      final slot = airtimes[item.id];
      final premiere = slot == null ? null : premiereOf(slot);
      return premiere == null
          ? null
          : TimelineAirtime(time: '', premiere: premiere);
    }

    final minCardWidth = scaler.scale(16) > 24 ? 440.0 : 340.0;
    return _TimelineScrollView(
      key: PageStorageKey('timeline-day-$day'),
      slivers: [
        if (groups.isNotEmpty)
          SliverPadding(
            padding:
                EdgeInsets.fromLTRB(inset, 0, inset, untimed.isEmpty ? 24 : 0),
            sliver: SliverLayoutBuilder(builder: (context, constraints) {
              final width =
                  constraints.crossAxisExtent - _TimelineNode.railWidth;
              final nodeColumns =
                  ((width + 12) / (minCardWidth + 12)).floor().clamp(1, 3);
              return SliverList.builder(
                itemCount: groups.length,
                itemBuilder: (context, index) {
                  final group = groups[index];
                  return _TimelineNode(
                    group: group,
                    state: states[index],
                    isFirst: index == 0,
                    isLast: index == groups.length - 1,
                    columns: nodeColumns,
                    cardHeight: BangumiTimelineCard.heightFor(scaler,
                        compact: compact,
                        withAirtime: group.items
                            .any((item) => premiereLine(item) != null)),
                    cardBuilder: (item) => card(item, premiereLine(item)),
                  );
                },
              );
            }),
          ),
        if (untimed.isNotEmpty) ...[
          if (groups.isNotEmpty)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 28, inset, 12),
              sliver: SliverToBoxAdapter(
                child: Text(
                  '时间未定',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: MonoPalette.of(context).secondaryLabel,
                  ),
                ),
              ),
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 0, inset, 24),
            sliver: grid(untimed, columns, (_) => null),
          ),
        ],
      ],
    );
  }
}

class _TimelineScrollView extends StatelessWidget {
  const _TimelineScrollView({super.key, required this.slivers});

  final List<Widget> slivers;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverOverlapInjector(
          handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
        ),
        ...slivers,
      ],
    );
  }
}

class _WeekHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _WeekHeaderDelegate({
    required this.height,
    required this.color,
    required this.child,
  });

  final double height;
  final Color color;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      ColoredBox(color: color, child: child);

  @override
  bool shouldRebuild(covariant _WeekHeaderDelegate oldDelegate) =>
      oldDelegate.height != height ||
      oldDelegate.color != color ||
      oldDelegate.child != child;
}
