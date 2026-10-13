import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/services/player/history_playback_service.dart';

void main() {
  late _Downloads downloads;
  late HistoryPlaybackService service;

  setUp(() {
    downloads = _Downloads();
    service = HistoryPlaybackService(downloads);
  });

  test(
    'old online history resumes without the removed rule or source URL',
    () async {
      final history = _history()
        ..lastWatchEpisode = 7
        ..lastSrc = ''
        ..progresses[7] = Progress(7, 3, 326500);

      final result = await service.open(history);
      final args =
          (result as HistoryPlaybackReady).args as OnlineVideoPlaybackArgs;
      expect(args.bangumiItem, same(history.bangumiItem));
      expect(args.initialEpisode, 7);
      expect(args.initialOffset, 326);
      expect(args.initialEpisodePageUrl, isEmpty);
      expect(downloads.lookups, isEmpty);
    },
  );

  test(
    'online history preserves a stable episode URL across catalog changes',
    () async {
      final history = _history()
        ..lastWatchEpisode = 3
        ..episodePageUrl = 'monogatari://episode/42/episode%3A1'
        ..progresses[3] = Progress(3, 0, 84000);

      final result = await service.open(history);
      final args =
          (result as HistoryPlaybackReady).args as OnlineVideoPlaybackArgs;
      // Episode 1 may have been appended at position 3 after gap filling.
      expect(args.initialEpisode, 3);
      expect(args.initialOffset, 84);
      expect(args.initialEpisodePageUrl, 'monogatari://episode/42/episode%3A1');
    },
  );

  test('legacy episode URLs retain the saved list-position fallback', () async {
    final history = _history()
      ..lastWatchEpisode = 8
      ..episodePageUrl = '/old-rule/episode-8.html';

    final result = await service.open(history);
    final args =
        (result as HistoryPlaybackReady).args as OnlineVideoPlaybackArgs;
    expect(args.initialEpisode, 8);
    expect(args.initialEpisodePageUrl, '/old-rule/episode-8.html');
  });

  test(
    'invalid legacy episode and negative progress use safe defaults',
    () async {
      final history = _history()
        ..lastWatchEpisode = 0
        ..progresses[1] = Progress(1, 0, -9000);

      final result = await service.open(history);
      final args =
          (result as HistoryPlaybackReady).args as OnlineVideoPlaybackArgs;
      expect(args.initialEpisode, 1);
      expect(args.initialOffset, 0);
    },
  );

  test(
    'offline history still selects the exact cached episode before its number',
    () async {
      final first = _episode(1, 'first')..road = 0;
      final exact = _episode(3, 'exact')..road = 2;
      downloads.episodes = [first, exact];
      downloads.localPath = '/cache/exact.m3u8';
      final history = _history()
        ..entryKind = HistoryEntryKind.offline
        ..lastWatchEpisode = 1
        ..episodePageUrl = 'exact';

      final result = await service.open(history);
      final args =
          (result as HistoryPlaybackReady).args as OfflineVideoPlaybackArgs;
      expect(args.pluginName, '旧规则');
      expect(args.episodeNumber, 3);
      expect(args.road, 2);
      expect(args.downloadedEpisodes, same(downloads.episodes));
      expect(downloads.lookups, [(42, '旧规则', 3)]);
    },
  );

  test(
    'missing offline media is reported without starting network playback',
    () async {
      final history = _history()..entryKind = HistoryEntryKind.offline;
      expect(await service.open(history), isA<HistoryPlaybackUnavailable>());

      downloads.episodes = [_episode(1, 'first')];
      downloads.localPath = null;
      expect(await service.open(history), isA<HistoryPlaybackUnavailable>());
    },
  );

  test(
    'a synchronized API slot never opens a different cached episode',
    () async {
      downloads.episodes = [_episode(1, 'monogatari://episode/42/episode%3A1')];
      downloads.localPath = '/cache/episode1.m3u8';
      final history = _history()
        ..entryKind = HistoryEntryKind.offline
        ..lastWatchEpisode = 1
        ..episodePageUrl = 'monogatari://episode/42/episode%3A2';
      expect(await service.open(history), isA<HistoryPlaybackUnavailable>());
      expect(downloads.lookups, isEmpty);
    },
  );

  test(
    'caller cancellation is honored before constructing playback arguments',
    () async {
      final token = CancelToken()..cancel('dialog dismissed');
      await expectLater(
        service.open(_history(), cancelToken: token),
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(downloads.lookups, isEmpty);
    },
  );
}

class _Downloads implements DownloadController {
  List<DownloadEpisode> episodes = [];
  String? localPath;
  final lookups = <(int, String, int)>[];

  @override
  List<DownloadEpisode> getCompletedEpisodes(
    int bangumiId,
    String pluginName,
  ) => episodes;

  @override
  String? getLocalVideoPath(
    int bangumiId,
    String pluginName,
    int episodeNumber,
  ) {
    lookups.add((bangumiId, pluginName, episodeNumber));
    return localPath;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

History _history() => History(
  BangumiItem(
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
  ),
  1,
  '旧规则',
  DateTime(2026),
  'https://removed.example/old.html',
  '第 1 集',
);

DownloadEpisode _episode(int number, String page) => DownloadEpisode(
  number,
  '第 $number 集',
  0,
  DownloadStatus.completed,
  1,
  1,
  1,
  '',
  '',
  '',
  DateTime(2026),
  '',
  0,
  page,
);
