import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/repositories/history_repository.dart';
import 'package:kazumi/services/api_video/api_video_service.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/player/playback_source_preferences.dart';
import 'package:kazumi/services/rss/rss_playback_resolver.dart';
import 'package:kazumi/services/rss/rss_subscription_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:kazumi/services/torrent/torrent_models.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform oldPaths;
  late VideoPageController controller;
  late _Resolver resolver;
  late _Api api;
  late PlaybackSourcePreferences preferences;
  Map<dynamic, dynamic> savedSources = {};
  final subject = BangumiItem(
    id: 42,
    type: 2,
    name: 'Test',
    nameCn: '测试',
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
  final subscription = RssSubscription(
    id: 'group',
    subject: subject,
    show: MikanShow(
      id: 1,
      title: '测试',
      detailUri: Uri.parse('https://mikanani.me/Home/Bangumi/1'),
      bangumiId: 42,
    ),
    group: MikanSubtitleGroup(
      id: 370,
      name: 'LoliHouse',
      feedUri: Uri.parse(
        'https://mikanani.me/RSS/Bangumi?bangumiId=1&subgroupid=370',
      ),
    ),
    createdAt: DateTime(2026),
  );
  RssRelease release(
    String key, {
    double? episode,
    List<double> batch = const [],
  }) => RssRelease(
    key: key,
    title: key,
    detailUri: Uri.parse('https://mikanani.me/Home/Episode/$key'),
    episodeNumber: episode,
    episodeNumbers: batch,
    isBatch: batch.isNotEmpty,
  );

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp(
      'monogatari_rss_player_test_',
    );
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = oldPaths;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    expect(directory.parent.path, Directory.systemTemp.path);
    expect(
      directory.path.split(Platform.pathSeparator).last,
      startsWith('monogatari_rss_player_test_'),
    );
    await directory.delete(recursive: true);
  });
  setUp(() async {
    await GStorage.putSetting(SettingsKeys.rssFallbackToApi, true);
    await GStorage.putSetting(SettingsKeys.playbackSource, 'api');
    savedSources = {};
    preferences = PlaybackSourcePreferences(
      read: () => savedSources,
      write: (value) async {
        savedSources = Map.of(value);
      },
    );
    resolver = _Resolver()
      ..catalog = RssPlaybackCatalog(subscription, [
        release('one', episode: 1),
        release('pack', batch: [1, 2, 3]),
      ]);
    api = _Api();
    controller = VideoPageController(
      HistoryController(_UnusedHistory()),
      _UnusedDownloads(),
      _UnusedManager(),
      api,
      rssPlayback: resolver,
      playbackPreferences: preferences,
    );
  });
  tearDown(() async {
    controller.dispose();
    resolver.subscriptions.dispose();
    await resolver.torrents.dispose();
  });

  test('explicit batch route selects requested content identity', () async {
    controller.applyPlaybackArgs(
      OnlineVideoPlaybackArgs(
        bangumiItem: subject,
        playbackSource: 'rss',
        rssReleaseId: 'pack',
        rssEpisodeNumber: 3,
      ),
    );
    expect(await controller.initializeOnline(), isTrue);
    expect(controller.requestedRssEpisodeIndex, 3);
    expect(controller.roadList.single.name, contains('LoliHouse'));
    expect(controller.roadList.single.data[2], 'monogatari://episode/42/3');
    expect(api.loads, 0);
  });
  test('unsubscribed RSS default falls back to API if enabled', () async {
    resolver.failure = const RssException('请先订阅');
    controller.applyPlaybackArgs(
      OnlineVideoPlaybackArgs(bangumiItem: subject, playbackSource: 'rss'),
    );
    expect(await controller.initializeOnline(), isTrue);
    expect(controller.playbackSource, 'api');
    expect(api.loads, 1);
    expect(preferences.forSubject(42), 'rss');
    controller.applyPlaybackArgs(OnlineVideoPlaybackArgs(bangumiItem: subject));
    expect(controller.playbackSource, 'rss');
  });
  test(
    'source is restored per subject while global default stays unchanged',
    () async {
      await preferences.remember(42, 'rss');
      controller.applyPlaybackArgs(
        OnlineVideoPlaybackArgs(bangumiItem: subject),
      );
      expect(controller.isRssPlayback, isTrue);
      expect(GStorage.getSetting(SettingsKeys.playbackSource), 'api');
      expect(preferences.forSubject(43), isNull);
      expect(await controller.initializeOnline(), isTrue);
      expect(
        await controller.restoreOnlineEpisode(
          pageUrl: 'monogatari://episode/42/3',
        ),
        3,
      );
      expect(controller.roadList.single.name, contains('LoliHouse'));
    },
  );
  test('an explicit API choice replaces this subject RSS preference', () async {
    await preferences.remember(42, 'rss');
    controller.applyPlaybackArgs(
      OnlineVideoPlaybackArgs(bangumiItem: subject, playbackSource: 'api'),
    );
    expect(controller.playbackSource, 'api');
    expect(preferences.forSubject(42), 'api');
  });
  test(
    'inferred historical RSS cannot overwrite a newer subject API choice',
    () async {
      await preferences.remember(42, 'api');
      controller.applyPlaybackArgs(
        OnlineVideoPlaybackArgs(
          bangumiItem: subject,
          playbackSource: 'rss',
          rememberPlaybackSource: false,
          torrentTaskId: 'old-task',
          torrentFileIndex: 0,
        ),
      );
      expect(await controller.initializeOnline(), isTrue);
      expect(controller.playbackSource, 'api');
      expect(controller.isDirectTorrentPlayback, isFalse);
      expect(preferences.forSubject(42), 'api');
      expect(
        await controller.restoreOnlineEpisode(
          pageUrl: 'monogatari://episode/42/torrent%3Aold-task%3A0',
          legacyEpisode: 1,
        ),
        isNull,
      );
    },
  );
  test('legacy RSS history can restore without creating a user preference', () {
    controller.applyPlaybackArgs(
      OnlineVideoPlaybackArgs(
        bangumiItem: subject,
        playbackSource: 'rss',
        rememberPlaybackSource: false,
      ),
    );
    expect(controller.isRssPlayback, isTrue);
    expect(preferences.forSubject(42), isNull);
  });
  test(
    'cached RSS starts immediately and refreshed episodes keep stable slots',
    () async {
      final refreshed = Completer<RssPlaybackCatalog?>();
      resolver.catalog = RssPlaybackCatalog(subscription, [
        release('three', episode: 3),
      ], refreshed: refreshed.future);
      controller.applyPlaybackArgs(
        OnlineVideoPlaybackArgs(bangumiItem: subject, playbackSource: 'rss'),
      );
      expect(await controller.initializeOnline(), isTrue);
      expect(controller.apiEpisodes.single.number, 3);
      expect(
        await controller.restoreOnlineEpisode(
          pageUrl: 'monogatari://episode/42/3',
        ),
        1,
      );
      final waiting = controller.restoreOnlineEpisode(
        pageUrl: 'monogatari://episode/42/2',
      );
      refreshed.complete(
        RssPlaybackCatalog(subscription, [
          release('one', episode: 1),
          release('two', episode: 2),
          release('three', episode: 3),
        ]),
      );
      expect(await waiting, 3);
      expect(controller.apiEpisodes.map((episode) => episode.number), [
        3,
        1,
        2,
      ]);
      expect(controller.isRssPlayback, isTrue);
      expect(api.loads, 0);
    },
  );
  test('a stale refresh cannot replace a newly opened API catalogue', () async {
    final refreshed = Completer<RssPlaybackCatalog?>();
    resolver.catalog = RssPlaybackCatalog(subscription, [
      release('one', episode: 1),
    ], refreshed: refreshed.future);
    controller.applyPlaybackArgs(
      OnlineVideoPlaybackArgs(bangumiItem: subject, playbackSource: 'rss'),
    );
    await controller.initializeOnline();
    controller.applyPlaybackArgs(
      OnlineVideoPlaybackArgs(bangumiItem: subject, playbackSource: 'api'),
    );
    await controller.initializeOnline();
    refreshed.complete(
      RssPlaybackCatalog(subscription, [release('two', episode: 2)]),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.playbackSource, 'api');
    expect(controller.apiEpisodes.map((episode) => episode.number), [1, 3]);
  });
  test('disabled fallback preserves RSS failure and selection', () async {
    await GStorage.putSetting(SettingsKeys.rssFallbackToApi, false);
    resolver.failure = const RssException('请先订阅');
    controller.applyPlaybackArgs(
      OnlineVideoPlaybackArgs(bangumiItem: subject, playbackSource: 'rss'),
    );
    expect(await controller.initializeOnline(), isFalse);
    expect(controller.errorMessage, '请先订阅');
    expect(controller.isRssPlayback, isTrue);
    expect(api.loads, 0);
  });
  test(
    'explicit unknown release does not silently start another episode',
    () async {
      controller.applyPlaybackArgs(
        OnlineVideoPlaybackArgs(
          bangumiItem: subject,
          playbackSource: 'rss',
          rssReleaseId: 'other-group',
          rssEpisodeNumber: 2,
        ),
      );
      expect(await controller.initializeOnline(), isTrue);
      expect(controller.requestedRssEpisodeIndex, isNull);
      controller.rejectRssRelease();
      expect(controller.loading, isFalse);
      expect(api.loads, 0);
    },
  );
  test(
    'history absent from selected RSS group restores same API content key',
    () async {
      resolver.catalog = RssPlaybackCatalog(subscription, [
        release('one', episode: 1),
      ]);
      controller.applyPlaybackArgs(
        OnlineVideoPlaybackArgs(bangumiItem: subject, playbackSource: 'rss'),
      );
      await controller.initializeOnline();
      expect(
        await controller.restoreOnlineEpisode(
          pageUrl: 'monogatari://episode/42/3',
        ),
        2,
      );
      expect(controller.apiEpisodes[1].number, 3);
      expect(controller.playbackSource, 'api');
    },
  );
  test(
    'disposed catalog request is cancelled and cannot install late result',
    () async {
      final pending = Completer<RssPlaybackCatalog>();
      resolver.pending = pending.future;
      controller.applyPlaybackArgs(
        OnlineVideoPlaybackArgs(bangumiItem: subject, playbackSource: 'rss'),
      );
      final loading = controller.initializeOnline();
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      pending.complete(resolver.catalog!);
      expect(await loading, isFalse);
      expect(resolver.token!.isCancelled, isTrue);
      expect(controller.apiEpisodes, isEmpty);
    },
  );
  test(
    'task file playback builds its catalogue without RSS or API lookup',
    () async {
      resolver.failure = StateError('RSS must not be accessed');
      (resolver.torrents as _Tasks).saved = [
        TorrentTaskSnapshot(
          id: 'cached',
          source: Uri.parse('magnet:?xt=urn:btih:cached'),
          title: '文件',
          bangumiId: 42,
          state: TorrentTaskState.completed,
          files: const [
            TorrentFileInfo(
              index: 0,
              name: 'Show - 03.mkv',
              size: 100,
              isVideo: true,
            ),
            TorrentFileInfo(
              index: 1,
              name: 'Show - 01.mkv',
              size: 100,
              isVideo: true,
            ),
          ],
        ),
      ];
      controller.applyPlaybackArgs(
        OnlineVideoPlaybackArgs(
          bangumiItem: subject,
          playbackSource: 'rss',
          torrentTaskId: 'cached',
          torrentFileIndex: 1,
        ),
      );
      expect(await controller.initializeOnline(), isTrue);
      expect(controller.requestedRssEpisodeIndex, 2);
      expect(controller.roadList.single.data[1], 'monogatari://episode/42/1');
      expect(api.loads, 0);
      expect(resolver.token, isNull);
    },
  );
  test(
    'a task belonging to another subject cannot fall back to a random episode',
    () async {
      (resolver.torrents as _Tasks).saved = [
        TorrentTaskSnapshot(
          id: 'other',
          source: Uri.parse('magnet:?xt=urn:btih:other'),
          title: '文件',
          bangumiId: 999,
          state: TorrentTaskState.completed,
        ),
      ];
      controller.applyPlaybackArgs(
        OnlineVideoPlaybackArgs(
          bangumiItem: subject,
          playbackSource: 'rss',
          torrentTaskId: 'other',
          torrentFileIndex: 0,
        ),
      );
      expect(await controller.initializeOnline(), isFalse);
      expect(api.loads, 0);
      expect(controller.errorMessage, contains('不属于当前番剧'));
    },
  );
}

class _Resolver extends RssPlaybackResolver {
  _Resolver()
    : super(
        RssSubscriptionService(repository: MemoryRssSubscriptionRepository()),
        _Tasks(),
      );
  RssPlaybackCatalog? catalog;
  Object? failure;
  Future<RssPlaybackCatalog>? pending;
  CancelToken? token;
  @override
  Future<RssPlaybackCatalog> load(
    int subjectId, {
    CancelToken? cancelToken,
  }) async {
    token = cancelToken;
    if (failure != null) throw failure!;
    return pending ?? Future.value(catalog!);
  }
}

class _Tasks extends TorrentService {
  List<TorrentTaskSnapshot> saved = [];
  @override
  Future<void> initialize() async {}
  @override
  List<TorrentTaskSnapshot> get tasks => saved;
}

class _Api extends ApiVideoService {
  int loads = 0;
  @override
  Future<ApiVideoCatalog> loadCatalog(
    BangumiItem subject, {
    CancelToken? cancelToken,
  }) async {
    loads++;
    return const ApiVideoCatalog(
      provider: ApiVideoProvider.zy1080,
      id: '1',
      title: '测试',
      episodes: [
        ApiVideoEpisode(key: '1', title: '第一话', number: 1),
        ApiVideoEpisode(key: '3', title: '第三话', number: 3),
      ],
    );
  }

  @override
  Stream<List<ApiVideoEpisode>> expandedEpisodes(
    BangumiItem subject,
    ApiVideoCatalog catalog, {
    CancelToken? cancelToken,
  }) => const Stream.empty();
}

class _UnusedHistory implements IHistoryRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('Unexpected history access');
}

class _UnusedDownloads implements IDownloadRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('Unexpected download access');
}

class _UnusedManager implements IDownloadManager {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('Unexpected download mutation');
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}
