import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/airing_summary.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/bangumi/broadcast_slot.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_progress.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/collect/collect_library_query.dart';

void main() {
  final today = DateTime(2026, 10, 13);

  List<EpisodeInfo> episodes(List<String> dates) => [
        for (var i = 0; i < dates.length; i++)
          EpisodeInfo(
            id: 100 + i,
            episode: i + 1,
            type: 0,
            name: '',
            nameCn: '',
            airDate: dates[i],
          ),
      ];

  group('AiringSummary', () {
    test('does not announce tonight before the exact broadcast time', () {
      final slot = BroadcastSlot(
        start: DateTime.utc(2026, 10, 1, 12, 30),
        periodDays: 7,
      ); // 21:30 JST
      final source = episodes(['2026-10-01', '2026-10-08', '2026-10-15']);
      final before = AiringSummary.of(
        source,
        slot: slot,
        today: DateTime.utc(2026, 10, 8, 11),
        requireBroadcastTime: true,
      );
      expect(before.latest!.displayNumber, 1);
      expect(before.next!.displayNumber, 2);
      expect(
        CollectProgress(history: _history(1), airing: before).hasUpdate,
        false,
      );
      final after = AiringSummary.of(
        source,
        slot: slot,
        today: DateTime.utc(2026, 10, 8, 12, 30),
        requireBroadcastTime: true,
      );
      expect(after.latest!.displayNumber, 2);
      expect(
        CollectProgress(history: _history(1), airing: after).hasUpdate,
        true,
      );
    });

    test('uses Japan time across midnight and the nominal late-night date', () {
      final slot = BroadcastSlot(
        start: DateTime.utc(2026, 10, 1, 16, 30),
        periodDays: 7,
      ); // Oct 2 at 01:30 JST; listed as Oct 1 late night
      final source = episodes(['2026-10-01', '2026-10-08']);
      final before = AiringSummary.of(
        source,
        slot: slot,
        today: DateTime.utc(2026, 10, 8, 16, 29),
        requireBroadcastTime: true,
      );
      expect(before.latest!.displayNumber, 1);
      final after = AiringSummary.of(
        source,
        slot: slot,
        today: DateTime.utc(2026, 10, 8, 16, 30),
        requireBroadcastTime: true,
      );
      expect(after.latest!.displayNumber, 2);
    });

    test('respects a rescheduled episode date rather than counting weeks', () {
      final slot = BroadcastSlot(
        start: DateTime.utc(2026, 10, 1, 12, 30),
        periodDays: 7,
      );
      final source = episodes(['2026-10-01', '2026-10-09']);
      expect(
        AiringSummary.of(
          source,
          slot: slot,
          today: DateTime.utc(2026, 10, 8, 14),
          requireBroadcastTime: true,
        ).latest!.displayNumber,
        1,
      );
    });

    test(
      'a missing clock time cannot establish availability earlier today',
      () {
        final source = episodes(['2026-10-01', '2026-10-08']);
        final before = AiringSummary.of(
          source,
          today: DateTime.utc(2026, 10, 8, 10),
          requireBroadcastTime: true,
        );
        expect(before.latest!.displayNumber, 1);
        final after = AiringSummary.of(
          source,
          today: DateTime.utc(2026, 10, 8, 15),
          requireBroadcastTime: true,
        );
        expect(after.latest!.displayNumber, 2);
      },
    );

    test('tracks the latest aired and the next episode', () {
      final summary = AiringSummary.of(
        episodes(['2026-10-01', '2026-10-08', '2026-10-15', '']),
        plannedTotal: 12,
        today: today,
      );
      expect(summary.state, AiringState.airing);
      expect(summary.total, 12);
      expect(summary.airedCount, 2);
      expect(summary.latest!.displayNumber, 2);
      expect(summary.next!.displayNumber, 3);
      expect(summary.finished, isFalse);
    });

    test('finishes once every planned episode has aired', () {
      final finished =
          AiringSummary.of(episodes(['2026-07-01', '2026-07-08']), today: today);
      expect(finished.state, AiringState.finished);
      final undated = AiringSummary.of(episodes(['', '']), today: today);
      expect(undated.state, AiringState.unknown);
      final upcoming =
          AiringSummary.of(episodes(['2026-11-01']), today: today);
      expect(upcoming.state, AiringState.upcoming);
    });
  });

  group('CollectProgress', () {
    final airing = AiringSummary.of(
      episodes(['2026-10-01', '2026-10-08', '2026-10-15']),
      plannedTotal: 12,
      today: today,
    );

    test('reports an update when a newer episode has aired', () {
      final progress = CollectProgress(history: _history(1), airing: airing);
      expect(progress.hasUpdate, isTrue);
      expect(progress.progressLabel, '看到第 1 话 · 更新至第 2 话');
      expect(CollectProgress(history: _history(2), airing: airing).hasUpdate,
          isFalse);
    });

    test('never reports an update for shows not played yet', () {
      final progress = CollectProgress(airing: airing);
      expect(progress.hasUpdate, isFalse);
      expect(progress.progressLabel, '更新至第 2 话');
      expect(const CollectProgress().progressLabel, isEmpty);
    });

    test('shows the weekly slot only while airing', () {
      final slot = BroadcastSlot(
        start: DateTime(2026, 10, 1, 20, 30).toUtc(),
        periodDays: 7,
      );
      final label = CollectProgress(airing: airing, slot: slot).scheduleLabel;
      expect(label, '每周四 20:30 更新');
      final finished = AiringSummary.of(episodes(['2026-07-01']), today: today);
      expect(CollectProgress(airing: finished, slot: slot).scheduleLabel,
          isNull);
      expect(CollectProgress(slot: slot).scheduleLabel, isNull);
    });
  });

  test('recently watched puts played shows first, then by change time', () {
    final entries = [
      CollectedBangumi(_item(1), DateTime(2026, 10, 1), CollectType.watching.value),
      CollectedBangumi(_item(2), DateTime(2026, 10, 5), CollectType.watching.value),
      CollectedBangumi(_item(3), DateTime(2026, 10, 3), CollectType.watching.value),
    ];
    final results = CollectLibraryQuery(entries, '').results(
      CollectType.watching,
      CollectSort.recentlyWatched,
      lastWatched: {1: DateTime(2026, 10, 12), 3: DateTime(2026, 10, 10)},
    );
    expect(results.map((entry) => entry.bangumiItem.id), [1, 3, 2]);
    expect(CollectSort.fromName('rating'), CollectSort.rating);
    expect(CollectSort.fromName('unknown'), CollectSort.recentlyWatched);
  });
}

History _history(int episode) =>
    History(_item(1), episode, 'plugin', DateTime(2026, 10, 12), '', '');

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
