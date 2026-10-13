import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/modules/history/history_sync.dart';
import 'package:kazumi/repositories/history_repository.dart';
import 'package:kazumi/services/sync/history_sync_service.dart';

void main() {
  late Directory directory;
  late Box<History> box;
  late HistoryRepository repository;
  final item = _subject();

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'monogatari_history_identity_',
    );
    Hive.init(directory.path);
    _registerAdapter(HistoryAdapter());
    _registerAdapter(ProgressAdapter());
    _registerAdapter(BangumiItemAdapter());
    _registerAdapter(BangumiTagAdapter());
    box = await Hive.openBox<History>('identity');
  });

  setUp(() async {
    await box.clear();
    repository = HistoryRepository(
      historiesBox: box,
      privateModeReader: () => false,
      progressSyncAppender:
          ({
            required history,
            required episode,
            required road,
            required progressMs,
            required updatedAt,
          }) async {},
      deleteSyncAppender: (_) async {},
      clearSyncAppender: () async {},
    );
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'each progress persists its stable episode URI across Hive reopening',
    () async {
      await repository.updateHistory(
        identity: _identity(item, 1, '1'),
        progress: const Duration(seconds: 20),
      );
      await box.close();
      box = await Hive.openBox<History>('identity');
      final history = box.get(History.getKey('自动播放', item))!;
      expect(
        history.progresses[1]!.episodePageUrl,
        'monogatari://episode/42/1',
      );
      expect(history.progresses[1]!.progress.inSeconds, 20);
    },
  );

  test(
    'a changed list slot preserves the displaced episode progress',
    () async {
      await repository.updateHistory(
        identity: _identity(item, 1, '1'),
        progress: const Duration(seconds: 30),
      );
      await repository.updateHistory(
        identity: _identity(item, 1, '3'),
        progress: const Duration(seconds: 60),
      );
      final history = repository.getHistory('自动播放', item)!;
      expect(
        history.progresses[1]!.episodePageUrl,
        'monogatari://episode/42/3',
      );
      expect(history.progresses[1]!.progress.inSeconds, 60);
      final displaced = history.progresses.values.singleWhere(
        (progress) => progress.episodePageUrl.endsWith('/1'),
      );
      expect(displaced.progress.inSeconds, 30);
      expect(displaced.episode, isNot(1));
      expect(history.progresses[displaced.episode], same(displaced));
    },
  );

  test(
    'revisiting an episode relocates its own identity without duplicate entries',
    () async {
      await repository.updateHistory(
        identity: _identity(item, 1, '1'),
        progress: const Duration(seconds: 30),
      );
      await repository.updateHistory(
        identity: _identity(item, 1, '3'),
        progress: const Duration(seconds: 60),
      );
      await repository.updateHistory(
        identity: _identity(item, 1, '1'),
        progress: const Duration(seconds: 45),
      );
      final history = repository.getHistory('自动播放', item)!;
      expect(history.progresses, hasLength(2));
      expect(
        history.progresses[1]!.episodePageUrl,
        'monogatari://episode/42/1',
      );
      expect(history.progresses[1]!.progress.inSeconds, 45);
      final retained = history.progresses.values.singleWhere(
        (progress) => progress.episodePageUrl.endsWith('/3'),
      );
      expect(retained.progress.inSeconds, 60);
    },
  );

  test('legacy Progress Hive fields use an empty URI by default', () {
    final progress = ProgressAdapter().read(
      _FieldsReader({0: 2, 1: 0, 2: 12345, 3: 1000}),
    );
    expect(progress.episodePageUrl, isEmpty);
    expect(progress.progress.inMilliseconds, 12345);
    expect(progress.updatedAtMs, 1000);
  });

  test('Progress sync JSON round-trips identity and reads old snapshots', () {
    final progress = Progress(
      3,
      0,
      20000,
      updatedAtMs: 1000,
      episodePageUrl: 'monogatari://episode/42/12.5',
    );
    final encoded = HistorySyncCodec.progressToJson(progress);
    final restored = HistorySyncCodec.progressFromJson(encoded);
    expect(restored.episodePageUrl, progress.episodePageUrl);
    expect(restored.progress, progress.progress);
    encoded.remove('episodePageUrl');
    expect(HistorySyncCodec.progressFromJson(encoded).episodePageUrl, isEmpty);
  });

  test(
    'state export uses each progress identity and never copies the latest to all episodes',
    () {
      final history = History(
        item,
        2,
        '自动播放',
        DateTime.fromMillisecondsSinceEpoch(2000),
        '',
        '第2集',
        episodePageUrl: 'monogatari://episode/42/2',
      );
      history.progresses = {
        1: Progress(1, 0, 1000, episodePageUrl: 'monogatari://episode/42/1'),
        2: Progress(2, 0, 2000),
        3: Progress(3, 0, 3000),
      };
      final progressEvents = HistorySyncService.buildStateEventsFromHistories([
        history,
      ]).where((event) => event.op == HistorySyncOp.upsertProgress).toList();
      expect(progressEvents.map((event) => event.episodePageUrl), [
        'monogatari://episode/42/1',
        'monogatari://episode/42/2',
        '',
      ]);
      final first = HistorySyncEvent.upsertProgress(
        deviceId: 'test',
        seq: 1,
        history: history,
        episode: 1,
        road: 0,
        progressMs: 1000,
        updatedAt: 1000,
      );
      expect(first.episodePageUrl, 'monogatari://episode/42/1');
    },
  );

  test(
    'sync merge stores an event URI and older formats retain an existing URI',
    () {
      HistorySyncEvent event(int sequence, {String? uri}) => HistorySyncEvent(
        eventId: 'test:$sequence',
        deviceId: 'test',
        seq: sequence,
        op: HistorySyncOp.upsertProgress,
        updatedAt: sequence * 1000,
        bangumiItem: item,
        adapterName: '自动播放',
        episode: 1,
        road: 0,
        progressMs: sequence * 10000,
        episodePageUrl: uri,
      );
      final first = HistorySyncMerger.merge(
        snapshot: HistorySyncSnapshot.empty(),
        events: [event(1, uri: 'monogatari://episode/42/1')],
      );
      expect(
        first.histories.single.progresses[1]!.episodePageUrl,
        'monogatari://episode/42/1',
      );
      final second = HistorySyncMerger.merge(
        snapshot: first,
        events: [event(2)],
      );
      expect(
        second.histories.single.progresses[1]!.episodePageUrl,
        'monogatari://episode/42/1',
      );
      expect(second.histories.single.progresses[1]!.progress.inSeconds, 20);
    },
  );
}

PlaybackHistoryIdentity _identity(BangumiItem item, int index, String key) =>
    PlaybackHistoryIdentity.online(
      bangumiItem: item,
      pluginName: '自动播放',
      episodeNumber: index,
      episodeTitle: '第$key集',
      road: 0,
      onlineBangumiSrc: 'monogatari://subject/42',
      episodePageUrl: 'monogatari://episode/42/$key',
    );

BangumiItem _subject() => BangumiItem(
  id: 42,
  type: 2,
  name: 'test',
  nameCn: '测试动画',
  summary: '',
  airDate: '2024-01-01',
  airWeekday: 1,
  rank: 0,
  images: {},
  tags: [],
  alias: [],
  ratingScore: 0,
  votes: 0,
  votesCount: [],
  info: '',
);

class _FieldsReader implements BinaryReader {
  _FieldsReader(Map<int, Object?> fields)
    : values = [
        fields.length,
        for (final entry in fields.entries) ...[entry.key, entry.value],
      ];
  final List<Object?> values;
  var index = 0;
  @override
  int readByte() => values[index++]! as int;
  @override
  dynamic read([int? typeId]) => values[index++];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _registerAdapter<T>(TypeAdapter<T> adapter) {
  if (!Hive.isAdapterRegistered(adapter.typeId)) {
    Hive.registerAdapter<T>(adapter);
  }
}
