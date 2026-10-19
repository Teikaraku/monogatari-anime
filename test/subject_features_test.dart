import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/collect/collect_progress.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/player/controller/track_choice.dart';
import 'package:kazumi/pages/season_preview/season_preview_deck.dart';
import 'package:kazumi/pages/subject/subject_poster.dart';
import 'package:kazumi/services/subject/subject_local_store.dart';
import 'package:kazumi/services/subject/subject_watch.dart';

void main() {
  group('SubjectMapStore', () {
    test('notes are trimmed, capped and removed when empty', () async {
      Map<dynamic, dynamic>? written;
      final notes = SubjectNotes(
        read: () => {'1': '旧备注', 'x': 'ignored', '2': ''},
        write: (value) async => written = value,
      );
      expect(notes.noteFor(1), '旧备注');
      expect(notes.noteFor(2), isNull);
      await notes.setNote(3, '  等完结   再看  ');
      expect(notes.noteFor(3), '等完结 再看');
      await notes.setNote(4, '好' * 80);
      expect(notes.noteFor(4)!.length, SubjectNotes.maxLength);
      await notes.setNote(1, '   ');
      expect(notes.noteFor(1), isNull);
      expect(written!.keys, unorderedEquals(['3', '4']));
    });

    test('episode marks merge and survive a round trip', () async {
      Map<dynamic, dynamic> stored = {};
      EpisodeMarks open() => EpisodeMarks(
        read: () => stored,
        write: (value) async => stored = value,
      );
      final marks = open();
      await marks.mark(7, [1, 2, 3], watched: true);
      await marks.mark(7, [2], watched: false);
      expect(open().marksFor(7), {1: true, 2: false, 3: true});
      expect(open().marksFor(8), isEmpty);
    });

    test('player choices keep only what was set', () async {
      Map<dynamic, dynamic> stored = {};
      final choices = SubjectPlayerChoices(
        read: () => stored,
        write: (value) async => stored = value,
      );
      await choices.update(5, speed: 1.25);
      await choices.update(
        5,
        subtitle: const TrackChoice(language: 'chs', title: '简体', index: 1),
      );
      await choices.update(5, danmaku: false);
      final restored = SubjectPlayerChoices(read: () => stored).choicesFor(5);
      expect(restored.speed, 1.25);
      expect(restored.danmaku, isFalse);
      expect(restored.audio, isNull);
      expect(restored.subtitle?.title, '简体');
      expect(restored.subtitle?.index, 1);
    });
  });

  group('SubjectWatch', () {
    History record(int id, Map<int, int> episodes, DateTime time) {
      final history = History(_item(id), episodes.keys.last, 'a', time, '', '');
      episodes.forEach((index, number) {
        history.progresses[index] = Progress(
          index,
          0,
          1000,
          episodePageUrl: 'monogatari://episode/$id/$number',
        );
      });
      return history;
    }

    test('combines every library and lets marks override records', () {
      final histories = [
        record(1, {1: 1, 2: 2}, DateTime(2026, 10, 1)),
        record(1, {1: 5}, DateTime(2026, 10, 3)),
        record(2, {1: 9}, DateTime(2026, 10, 4)),
      ];
      final plain = SubjectWatch.of(histories, 1);
      expect(plain.watched, {1, 2, 5});
      expect(plain.latest!.lastWatchTime, DateTime(2026, 10, 3));

      final marked = SubjectWatch.of(
        histories,
        1,
        marks: const {2: false, 8: true},
      );
      expect(marked.watched, {1, 5, 8});
      expect(marked.lastWatched, 8);
    });

    test('progress counts the furthest marked episode', () {
      const progress = CollectProgress(lastWatched: 6);
      expect(progress.watchedEpisode, 6);
      expect(progress.progressLabel, '看到第 6 话');
    });
  });

  group('track choice', () {
    const tracks = <TrackInfo>[
      (id: '1', title: '简体中文', language: 'chi'),
      (id: '2', title: '繁體中文', language: 'chi'),
      (id: '3', title: null, language: 'jpn'),
    ];

    test('prefers language and title, then title, language, position', () {
      expect(
        matchTrackIndex(
          tracks,
          const TrackChoice(title: '繁體中文', language: 'chi'),
        ),
        1,
      );
      expect(matchTrackIndex(tracks, const TrackChoice(title: '繁體中文')), 1);
      expect(matchTrackIndex(tracks, const TrackChoice(language: 'JPN')), 2);
      expect(matchTrackIndex(tracks, const TrackChoice(index: 2)), 2);
      expect(matchTrackIndex(tracks, const TrackChoice(index: 9)), isNull);
      expect(matchTrackIndex(tracks, const TrackChoice(off: true)), isNull);
    });

    test('labels name the language or fall back to a number', () {
      expect(trackLabel(tracks[0], 0, '字幕'), '简体中文 · 中文');
      expect(trackLabel(tracks[2], 2, '字幕'), '日语');
      expect(
        trackLabel((id: '4', title: null, language: 'und'), 3, '音轨'),
        '音轨 4',
      );
    });
  });

  group('SeasonPreviewDeck', () {
    test('drops decided shows, sorts by popularity and undoes', () {
      final shows = [
        _item(1, votes: 10),
        _item(2, votes: 300),
        _item(3, votes: 50),
        _item(2, votes: 300),
      ];
      final deck = SeasonPreviewDeck(
        SeasonPreviewDeck.arrange(shows, exclude: {3}),
      );
      expect(deck.items.map((item) => item.id), [2, 1]);
      expect(deck.current!.id, 2);
      expect(deck.next!.id, 1);
      deck.decide(PreviewDecision.planToWatch);
      expect(deck.current!.id, 1);
      expect(deck.remaining, 1);
      final undone = deck.undo()!;
      expect(undone.$1.id, 2);
      expect(undone.$2, PreviewDecision.planToWatch);
      expect(deck.current!.id, 2);
      deck
        ..decide(PreviewDecision.skip)
        ..decide(PreviewDecision.watching);
      expect(deck.isDone, isTrue);
      expect(deck.current, isNull);
    });

    test('season keys group three months', () {
      expect(SeasonPreviewStore.seasonKey(DateTime(2026, 10, 15)), '2026-3');
      expect(SeasonPreviewStore.seasonKey(DateTime(2026, 1, 1)), '2026-0');
    });
  });

  testWidgets('the poster lays out without a cover or overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SubjectPoster(
            item: _item(9, votes: 1, rating: 8.4, rank: 12),
            note: '第 5 话之后才好看',
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('“第 5 话之后才好看”'), findsOneWidget);
    expect(find.text('★ 8.4'), findsOneWidget);
    expect(subjectLink(_item(9)), 'https://bgm.tv/subject/9');
  });
}

BangumiItem _item(int id, {int votes = 0, double rating = 0, int rank = 0}) =>
    BangumiItem(
      id: id,
      type: 2,
      name: 'subject $id',
      nameCn: '条目 $id',
      summary: '',
      airDate: '2026-10-01',
      airWeekday: 4,
      rank: rank,
      images: const {},
      tags: const <BangumiTag>[],
      alias: const [],
      ratingScore: rating,
      votes: votes,
      votesCount: const [],
      info: '',
    );
