import 'dart:async';

import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/broadcast_slot.dart';
import 'package:kazumi/request/apis/airtime_api.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/utils/anime_season.dart';
import 'package:kazumi/repositories/collect_repository.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:mobx/mobx.dart';

part 'timeline_controller.g.dart';

enum TimelineSort { airTime, popularity, rating, defaultOrder }

class TimelineController = _TimelineController with _$TimelineController;

abstract class _TimelineController with Store {
  _TimelineController(this._collectRepository);

  final ICollectRepository _collectRepository;

  @observable
  ObservableList<List<BangumiItem>> bangumiCalendar =
      ObservableList<List<BangumiItem>>();

  @readonly
  DateTime _selectedDate = DateTime.now();

  @observable
  bool isLoading = false;

  @observable
  bool isTimeOut = false;

  @observable
  late bool notShowAbandonedBangumis =
      _collectRepository.getTimelineNotShowAbandonedBangumis();

  @observable
  late bool notShowWatchedBangumis =
      _collectRepository.getTimelineNotShowWatchedBangumis();

  @observable
  late bool onlyShowWatchingBangumis =
      _collectRepository.getTimelineOnlyShowWatchingBangumis();

  @readonly
  TimelineSort _sort = TimelineSort.airTime;

  /// Broadcast times by subject id; empty until loaded or when unavailable.
  Map<int, BroadcastSlot> airtimes = const {};
  int _loadGeneration = 0;

  Future<void> _loadAirtimes() async {
    try {
      airtimes = await AirtimeApi.load();
    } catch (error) {
      KazumiLogger().w('Timeline: broadcast times unavailable', error: error);
    }
  }

  @action
  Future<void> loadSeason(DateTime date) async {
    if (isLoading) return;
    final generation = ++_loadGeneration;
    isLoading = true;
    isTimeOut = false;
    final airtimesLoaded = _loadAirtimes();
    try {
      _selectedDate = date;
      bangumiCalendar.clear();
      final calendar = isSameSeason(date, DateTime.now())
          ? await BangumiApi.getCalendar()
          : await BangumiApi.getSeasonCalendar(
              AnimeSeason(date).toSeasonStartAndEnd(),
            );
      // Broadcast clock metadata is optional; a slow metadata host must not
      // hide the already downloaded calendar behind the loading indicator.
      bangumiCalendar.addAll(_byBroadcastDay(calendar));
      isTimeOut = bangumiCalendar.every((day) => day.isEmpty);
      if (!isTimeOut) changeSort(_sort);
      unawaited(
        airtimesLoaded.then((_) {
          if (_loadGeneration != generation || isTimeOut) return;
          runInAction(() {
            bangumiCalendar
              ..clear()
              ..addAll(_byBroadcastDay(calendar));
            changeSort(_sort);
          });
        }),
      );
    } catch (error, stackTrace) {
      isTimeOut = true;
      KazumiLogger().e('Timeline: loading season failed',
          error: error, stackTrace: stackTrace);
    } finally {
      isLoading = false;
    }
  }

  /// Bangumi groups shows by their Japanese broadcast day. Shows with a known
  /// time move to the day they air in the device's time zone, so a 00:30 JST
  /// show sits on the previous evening in Beijing. The first broadcast decides
  /// the day even when bangumi-data has no repeat period: the timetable only
  /// lists series.
  List<List<BangumiItem>> _byBroadcastDay(List<List<BangumiItem>> days) {
    final result = List.generate(7, (_) => <BangumiItem>[]);
    final placed = <int>{};
    for (var day = 0; day < days.length && day < 7; day++) {
      for (final item in days[day]) {
        if (!placed.add(item.id)) continue;
        final slot = airtimes[item.id];
        result[slot != null ? slot.localWeekday - 1 : day].add(item);
      }
    }
    return result;
  }

  @action
  void changeSort(TimelineSort sort) {
    _sort = sort;
    final resBangumiCalendar = bangumiCalendar.toList();
    for (var day = 0; day < resBangumiCalendar.length; day++) {
      resBangumiCalendar[day].sort(switch (sort) {
        TimelineSort.airTime => _byAirtime(day + 1),
        TimelineSort.popularity => (a, b) => b.votes.compareTo(a.votes),
        TimelineSort.rating => (a, b) => b.ratingScore.compareTo(a.ratingScore),
        TimelineSort.defaultOrder => (a, b) => a.id.compareTo(b.id),
      });
    }
    bangumiCalendar.clear();
    bangumiCalendar.addAll(resBangumiCalendar);
  }

  /// Earliest broadcast first in the column of ISO [weekday]; subjects without
  /// a known time follow, by popularity.
  Comparator<BangumiItem> _byAirtime(int weekday) => (a, b) {
        final slotA = airtimes[a.id];
        final slotB = airtimes[b.id];
        if (slotA == null || slotB == null) {
          if (slotA != null) return -1;
          if (slotB != null) return 1;
          return b.votes.compareTo(a.votes);
        }
        final byTime = slotA
            .minuteInColumn(weekday)
            .compareTo(slotB.minuteInColumn(weekday));
        return byTime != 0 ? byTime : b.votes.compareTo(a.votes);
      };

  @action
  Future<void> setNotShowAbandonedBangumis(bool value) async {
    notShowAbandonedBangumis = value;
    await _collectRepository.updateTimelineNotShowAbandonedBangumis(value);
  }

  @action
  Future<void> setNotShowWatchedBangumis(bool value) async {
    notShowWatchedBangumis = value;
    await _collectRepository.updateTimelineNotShowWatchedBangumis(value);
  }

  @action
  Future<void> setOnlyShowWatchingBangumis(bool value) async {
    onlyShowWatchingBangumis = value;
    await _collectRepository.updateTimelineOnlyShowWatchingBangumis(value);
  }

  Set<int> loadWatchingBangumiIds() {
    return _collectRepository.getBangumiIdsByType(CollectType.watching);
  }

  int get activeFilterCount => [
        onlyShowWatchingBangumis,
        notShowWatchedBangumis,
        notShowAbandonedBangumis,
      ].where((enabled) => enabled).length;

  List<List<BangumiItem>> filterCalendar(Set<int> watchingIds) {
    final abandonedIds = notShowAbandonedBangumis
        ? _collectRepository.getBangumiIdsByType(CollectType.abandoned)
        : <int>{};
    final watchedIds = notShowWatchedBangumis
        ? _collectRepository.getBangumiIdsByType(CollectType.watched)
        : <int>{};
    final onlyWatching = onlyShowWatchingBangumis;
    return List.generate(7, (day) {
      if (day >= bangumiCalendar.length) return <BangumiItem>[];
      return bangumiCalendar[day]
          .where((item) =>
              !abandonedIds.contains(item.id) &&
              !watchedIds.contains(item.id) &&
              (!onlyWatching || watchingIds.contains(item.id)))
          .toList();
    });
  }

  @action
  Future<void> clearFilters() async {
    await Future.wait([
      setNotShowAbandonedBangumis(false),
      setNotShowWatchedBangumis(false),
      setOnlyShowWatchingBangumis(false),
    ]);
  }
}
