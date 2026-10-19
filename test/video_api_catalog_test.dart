import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/repositories/history_repository.dart';
import 'package:kazumi/services/api_video/api_video_service.dart';
import 'package:kazumi/services/download/download_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VideoPageController controller;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  setUp(() {
    controller =
        VideoPageController(
            HistoryController(_UnusedHistoryRepository()),
            _UnusedDownloadRepository(),
            _UnusedDownloadManager(),
            ApiVideoService(
              transport: (_, _) async =>
                  fail('catalog mapping must not query an API'),
            ),
          )
          ..bangumiItem = _subject()
          ..apiEpisodes = const [
            ApiVideoEpisode(key: '2', title: '第 2 集', number: 2),
            ApiVideoEpisode(key: '3', title: '第 3 集', number: 3),
            ApiVideoEpisode(key: '1', title: '第 1 集', number: 1),
          ];
  });

  tearDown(() async {
    await controller.fullscreen.close();
    controller.dispose();
  });

  test('stable episode URL restores its identity after gap filling', () async {
    expect(
      await controller.restoreOnlineEpisode(
        pageUrl: 'monogatari://episode/42/1',
        legacyEpisode: 1,
      ),
      3,
    );
  });

  test(
    'a missing stable episode reports failure instead of an unrelated index',
    () async {
      expect(
        await controller.restoreOnlineEpisode(
          pageUrl: 'monogatari://episode/42/10',
          legacyEpisode: 1,
        ),
        isNull,
      );
      expect(controller.errorMessage, contains('上次观看的剧集'));
      expect(controller.loading, isFalse);
      expect(controller.currentHistoryIdentity, isNull);
      expect(controller.playingEpisode, isNull);
    },
  );

  test(
    'legacy HTML and missing URLs still use the saved list position',
    () async {
      expect(
        await controller.restoreOnlineEpisode(
          pageUrl: 'https://old-source.example/episode-2.html',
          legacyEpisode: 2,
        ),
        2,
      );
      expect(await controller.restoreOnlineEpisode(legacyEpisode: 3), 3);
      expect(await controller.restoreOnlineEpisode(legacyEpisode: 0), 1);
      expect(await controller.restoreOnlineEpisode(legacyEpisode: 4), 1);
    },
  );

  test(
    'automatic next and previous episode follow content order, not append order',
    () {
      // List positions are [episode 2, episode 3, episode 1].
      expect(controller.adjacentOnlineEpisode(3, forward: true), 1);
      expect(controller.adjacentOnlineEpisode(2, forward: false), 1);
      expect(controller.adjacentOnlineEpisode(1, forward: true), 2);
      expect(controller.adjacentOnlineEpisode(1, forward: false), 3);
      expect(controller.adjacentOnlineEpisode(2, forward: true), isNull);
      expect(controller.adjacentOnlineEpisode(3, forward: false), isNull);
      expect(controller.adjacentOnlineEpisode(0, forward: true), isNull);
      expect(controller.adjacentOnlineEpisode(4, forward: false), isNull);
    },
  );

  test(
    'manual episode choice invalidates delayed startup history restoration',
    () async {
      final startup = controller.beginOnlineStartup();
      final player = _PendingPlayer();
      final changed = controller.changeEpisode(2, playerController: player);
      expect(startup.isStale, isTrue);
      expect(
        await controller.restoreOnlineEpisode(
          pageUrl: 'monogatari://episode/42/10',
          startupSession: startup,
        ),
        isNull,
      );
      expect(controller.selectedEpisode.episode, 2);
      expect(controller.errorMessage, isNull);
      controller.dispose();
      player.stopped.complete();
      await changed;
    },
  );
}

class _PendingPlayer implements PlayerController {
  final stopped = Completer<void>();
  @override
  final danmaku = _NoopDanmaku();
  @override
  bool Function(String error)? onPlaybackError;
  @override
  Future<void> stop() => stopped.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => fail(
    'startup cancellation must not open media: ${invocation.memberName}',
  );
}

class _NoopDanmaku implements PlayerDanmakuController {
  @override
  void finishDanmakuLoad({bool disableDanmaku = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => fail(
    'startup cancellation must not load danmaku: ${invocation.memberName}',
  );
}

class _UnusedHistoryRepository implements IHistoryRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('catalog mapping must not access history: ${invocation.memberName}');
}

class _UnusedDownloadRepository implements IDownloadRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => fail(
    'catalog mapping must not access downloads: ${invocation.memberName}',
  );
}

class _UnusedDownloadManager implements IDownloadManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => fail(
    'catalog mapping must not use the downloader: ${invocation.memberName}',
  );
}

BangumiItem _subject() => BangumiItem(
  id: 42,
  type: 2,
  name: 'Test anime',
  nameCn: '测试番剧',
  summary: '',
  airDate: '',
  airWeekday: 0,
  rank: 0,
  images: const {},
  tags: const [],
  alias: const [],
  ratingScore: 0,
  votes: 0,
  votesCount: const [],
  info: '',
);
