import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/history/history_module.dart';

/// One episode in the watch log: when it was last played.
class WatchedEpisode {
  const WatchedEpisode({
    required this.bangumiItem,
    required this.episode,
    required this.watchedAt,
  });

  final BangumiItem bangumiItem;
  final int episode;
  final DateTime watchedAt;
}

/// Viewing activity by local calendar day, built from the watch history.
/// Each episode counts once, on the day it was last played; episodes played
/// from several rules or offline count once too.
class WatchActivity {
  WatchActivity._(this._byDay, this.bangumiCount, this.episodeCount);

  factory WatchActivity.from(Iterable<History> histories) {
    final latest = <(int, int), WatchedEpisode>{};
    for (final history in histories) {
      for (final MapEntry(key: episode, value: progress)
          in history.progresses.entries) {
        final watchedAt = DateTime.fromMillisecondsSinceEpoch(
            progress.effectiveUpdatedAtMs(history.lastWatchTime));
        final key = (history.bangumiItem.id, episode);
        final current = latest[key];
        if (current == null || watchedAt.isAfter(current.watchedAt)) {
          latest[key] = WatchedEpisode(
            bangumiItem: history.bangumiItem,
            episode: episode,
            watchedAt: watchedAt,
          );
        }
      }
    }
    final byDay = <DateTime, List<WatchedEpisode>>{};
    for (final watched in latest.values) {
      byDay.putIfAbsent(dayOf(watched.watchedAt), () => []).add(watched);
    }
    for (final list in byDay.values) {
      list.sort((a, b) => b.watchedAt.compareTo(a.watchedAt));
    }
    return WatchActivity._(
      byDay,
      latest.keys.map((key) => key.$1).toSet().length,
      latest.length,
    );
  }

  final Map<DateTime, List<WatchedEpisode>> _byDay;
  final int bangumiCount;
  final int episodeCount;

  static DateTime dayOf(DateTime time) =>
      DateTime(time.year, time.month, time.day);

  /// Episodes last played on [day], newest first.
  List<WatchedEpisode> on(DateTime day) => _byDay[dayOf(day)] ?? const [];

  int countOn(DateTime day) => on(day).length;

  /// The latest day with any activity, if there is one.
  DateTime? get lastActiveDay => _byDay.isEmpty
      ? null
      : _byDay.keys.reduce((a, b) => a.isAfter(b) ? a : b);

  /// Days with activity in [from, to], both inclusive.
  int activeDaysBetween(DateTime from, DateTime to) {
    final first = dayOf(from);
    final last = dayOf(to);
    return _byDay.keys
        .where((day) => !day.isBefore(first) && !day.isAfter(last))
        .length;
  }

  /// Episodes in [from, to], both inclusive.
  int episodesBetween(DateTime from, DateTime to) {
    final first = dayOf(from);
    final last = dayOf(to);
    return _byDay.entries
        .where((e) => !e.key.isBefore(first) && !e.key.isAfter(last))
        .fold(0, (sum, e) => sum + e.value.length);
  }

  /// Consecutive active days up to [today]; a quiet today does not break it.
  int currentStreak(DateTime today) {
    var day = dayOf(today);
    if (countOn(day) == 0) day = _previous(day);
    var streak = 0;
    while (countOn(day) > 0) {
      streak++;
      day = _previous(day);
    }
    return streak;
  }

  int get longestStreak {
    final days = _byDay.keys.toList()..sort();
    var longest = 0;
    var run = 0;
    DateTime? previous;
    for (final day in days) {
      run = previous != null && _previous(day) == previous ? run + 1 : 1;
      if (run > longest) longest = run;
      previous = day;
    }
    return longest;
  }

  // Calendar arithmetic, so daylight-saving changes cannot skip a day.
  static DateTime _previous(DateTime day) =>
      DateTime(day.year, day.month, day.day - 1);
}
