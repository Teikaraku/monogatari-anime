import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/modules/history/watch_activity.dart';

void main() {
  int at(int month, int day, [int hour = 20]) =>
      DateTime(2026, month, day, hour).millisecondsSinceEpoch;

  History history(int id, String adapter, Map<int, int> episodesAt) {
    final record = History(
        _item(id), episodesAt.keys.last, adapter, DateTime(2026, 10, 1), '', '');
    episodesAt.forEach((episode, time) {
      record.progresses[episode] = Progress(episode, 0, 1000, updatedAtMs: time);
    });
    return record;
  }

  test('counts each episode once, on the day it was last played', () {
    final activity = WatchActivity.from([
      history(1, 'a', {1: at(10, 10), 2: at(10, 11)}),
      // The same episode from another rule, played later, wins.
      history(1, 'b', {2: at(10, 12)}),
      history(2, 'a', {1: at(10, 12, 9)}),
    ]);
    expect(activity.bangumiCount, 2);
    expect(activity.episodeCount, 3);
    expect(activity.countOn(DateTime(2026, 10, 10)), 1);
    expect(activity.countOn(DateTime(2026, 10, 11)), 0);
    expect(activity.countOn(DateTime(2026, 10, 12)), 2);
    // Newest first within a day.
    expect(activity.on(DateTime(2026, 10, 12)).first.bangumiItem.id, 1);
    expect(activity.lastActiveDay, DateTime(2026, 10, 12));
    expect(
        activity.episodesBetween(DateTime(2026, 10, 11), DateTime(2026, 10, 12)),
        2);
    expect(
        activity.activeDaysBetween(DateTime(2026, 10, 1), DateTime(2026, 10, 31)),
        2);
  });

  test('streaks run over consecutive days and survive a quiet today', () {
    final activity = WatchActivity.from([
      history(1, 'a', {
        1: at(10, 1),
        2: at(10, 2),
        3: at(10, 3),
        4: at(10, 7),
        5: at(10, 8),
      }),
    ]);
    expect(activity.longestStreak, 3);
    expect(activity.currentStreak(DateTime(2026, 10, 8)), 2);
    expect(activity.currentStreak(DateTime(2026, 10, 9)), 2);
    expect(activity.currentStreak(DateTime(2026, 10, 10)), 0);
    expect(WatchActivity.from(const []).longestStreak, 0);
  });
}

BangumiItem _item(int id) {
  return BangumiItem(
    id: id,
    type: 2,
    name: 'subject $id',
    nameCn: '条目 $id',
    summary: '',
    airDate: '2026-10-01',
    airWeekday: 4,
    rank: 0,
    images: const {
      'large': '',
      'common': '',
      'medium': '',
      'small': '',
      'grid': '',
    },
    tags: const <BangumiTag>[],
    alias: const [],
    ratingScore: 0,
    votes: 0,
    votesCount: const [],
    info: '',
  );
}
