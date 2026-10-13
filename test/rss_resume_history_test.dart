import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/repositories/history_repository.dart';
import 'package:kazumi/services/api_video/api_video_service.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/rss/rss_models.dart';
import 'package:kazumi/services/rss/rss_playback_resolver.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform originalPaths;
  late HistoryRepository repository;
  late VideoPageController controller;
  final subject = _subject();

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp(
      'monogatari_rss_resume_history_',
    );
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  setUp(() async {
    await GStorage.histories.clear();
    await GStorage.putSetting(SettingsKeys.playResume, true);
    repository = HistoryRepository(
      historiesBox: GStorage.histories,
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
    controller =
        VideoPageController(
            HistoryController(repository),
            _UnusedDownloads(),
            _UnusedManager(),
            _UnusedApi(),
          )
          ..bangumiItem = subject
          ..playbackSource = 'rss';
  });

  tearDown(() async {
    await controller.fullscreen.close();
    controller.dispose();
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    expect(directory.parent.path, Directory.systemTemp.path);
    expect(
      directory.path.split(Platform.pathSeparator).last,
      startsWith('monogatari_rss_resume_history_'),
    );
    await directory.delete(recursive: true);
  });

  test(
    'opening the same RSS episode restores its own progress repeatedly',
    () async {
      final identity = _identity(subject, slot: 3, contentNumber: 12);
      await repository.updateHistory(
        identity: identity,
        progress: const Duration(milliseconds: 84500),
      );

      expect(controller.getHistoryOffsetFor(identity), 84);
      expect(controller.getHistoryOffsetFor(identity), 84);
      expect(
        repository
            .getHistory(apiPlaybackLibraryName, subject)!
            .progresses[3]!
            .progress
            .inMilliseconds,
        84500,
      );
    },
  );

  test(
    'another RSS episode never inherits the most recently watched offset',
    () async {
      await repository.updateHistory(
        identity: _identity(subject, slot: 2, contentNumber: 1),
        progress: const Duration(seconds: 55),
      );
      await repository.updateHistory(
        identity: _identity(subject, slot: 7, contentNumber: 2),
        progress: const Duration(seconds: 120),
      );
      final history = repository.getHistory(apiPlaybackLibraryName, subject)!;
      expect(history.lastWatchEpisode, 7);

      // A different group can put episode 1 in the latest episode's old slot.
      expect(
        controller.getHistoryOffsetFor(
          _identity(subject, slot: 7, contentNumber: 1),
        ),
        55,
      );
      expect(
        controller.getHistoryOffsetFor(
          _identity(subject, slot: 7, contentNumber: 3),
        ),
        0,
      );
    },
  );

  test(
    'changing subtitle group preserves the same stable episode progress',
    () async {
      final first = _release('group-a-resource', '字幕组 A', 12.5);
      final second = _release('group-b-resource', '字幕组 B', 12.5);
      final firstEpisode = rssEpisodes([first]).single;
      final secondEpisode = rssEpisodes([second]).single;
      final firstPage = apiEpisodePageUrl(subject.id, firstEpisode);
      final secondPage = apiEpisodePageUrl(subject.id, secondEpisode);
      expect(first.key, isNot(second.key));
      expect(first.group, isNot(second.group));
      expect(firstPage, secondPage);

      await repository.updateHistory(
        identity: _identity(subject, slot: 4, pageUrl: firstPage),
        progress: const Duration(seconds: 97),
      );
      expect(
        controller.getHistoryOffsetFor(
          _identity(subject, slot: 1, pageUrl: secondPage),
        ),
        97,
      );
    },
  );

  test(
    'disabling resume ignores saved RSS progress without erasing it',
    () async {
      final identity = _identity(subject, slot: 2, contentNumber: 2);
      await repository.updateHistory(
        identity: identity,
        progress: const Duration(seconds: 90),
      );
      await GStorage.putSetting(SettingsKeys.playResume, false);
      expect(controller.getHistoryOffsetFor(identity), 0);
      await GStorage.putSetting(SettingsKeys.playResume, true);
      expect(controller.getHistoryOffsetFor(identity), 90);
    },
  );
}

PlaybackHistoryIdentity _identity(
  BangumiItem subject, {
  required int slot,
  int? contentNumber,
  String? pageUrl,
}) => PlaybackHistoryIdentity.online(
  bangumiItem: subject,
  pluginName: apiPlaybackLibraryName,
  episodeNumber: slot,
  episodeTitle: 'RSS 视频',
  road: 0,
  onlineBangumiSrc: 'monogatari://subject/${subject.id}',
  episodePageUrl:
      pageUrl ?? 'monogatari://episode/${subject.id}/$contentNumber',
);

RssRelease _release(String key, String group, double number) => RssRelease(
  key: key,
  title: '$group 第 $number 话',
  group: group,
  detailUri: Uri.parse('https://mikanani.me/Home/Episode/$key'),
  episodeNumber: number,
);

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

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String> getApplicationSupportPath() async => path;
}

class _UnusedDownloads implements IDownloadRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => fail(
    'resume history must not access downloads: ${invocation.memberName}',
  );
}

class _UnusedManager implements IDownloadManager {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('resume history must not start downloads: ${invocation.memberName}');
}

class _UnusedApi implements ApiVideoService {
  @override
  dynamic noSuchMethod(Invocation invocation) => fail(
    'resume history must not request catalogs: ${invocation.memberName}',
  );
}
