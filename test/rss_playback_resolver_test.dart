import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/api_video/api_video_models.dart';
import 'package:kazumi/services/rss/rss_models.dart';
import 'package:kazumi/services/rss/rss_playback_resolver.dart';
import 'package:kazumi/services/torrent/torrent_models.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:dio/dio.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:kazumi/services/rss/rss_subscription_service.dart';
import 'package:kazumi/services/rss/rss_subscription_repository.dart';
import 'api_video_service_test.dart' as fixture;

RssRelease release(
  String key, {
  double? number,
  List<double> batch = const [],
  bool special = false,
  DateTime? date,
}) => RssRelease(
  key: key,
  title: key,
  detailUri: Uri.parse('https://mikanani.me/Home/Episode/$key'),
  torrentUri: Uri.parse('https://mikanani.me/Download/$key.torrent'),
  episodeNumber: number,
  episodeNumbers: batch,
  isBatch: batch.isNotEmpty,
  isSpecial: special,
  specialKey: special ? 'sp1' : null,
  publishedAt: date,
);
TorrentFileInfo file(int index, String name) =>
    TorrentFileInfo(index: index, name: name, size: 1024, isVideo: true);
const episode = ApiVideoEpisode(key: '2', title: '第二话', number: 2);

void main() {
  test(
    'playback selects raw file 13 while saving season episode 1 to the BT task',
    () async {
      final subscriptions = _UnusedSubscriptions();
      final tasks = _PlaybackTasks();
      final resolver = RssPlaybackResolver(subscriptions, tasks);
      final subscription = RssSubscription(
        id: 'group',
        subject: fixture.subject(),
        show: MikanShow(
          id: 1,
          title: 'Show',
          detailUri: Uri.parse('https://mikanani.me/Home/Bangumi/1'),
        ),
        group: MikanSubtitleGroup(
          id: 2,
          name: 'Group',
          feedUri: Uri.parse(
            'https://mikanani.me/RSS/Bangumi?bangumiId=1&subgroupid=2',
          ),
        ),
        createdAt: DateTime(2026),
      );
      final catalog = RssPlaybackCatalog(
        subscription,
        [release('13', number: 13)],
        episodeNumbers: {13: 1},
      );
      final lease = await resolver.open(
        catalog,
        catalog.episodes.single,
        cancelToken: CancelToken(),
      );
      expect(tasks.logicalNumber, 1);
      expect(tasks.openedFile, 1);
      await lease.close();
      subscriptions.dispose();
    },
  );
  test('verified continuation numbering maps 13 to season episode 1', () {
    final numbers = rssSeasonNumbering([
      EpisodeInfo(
        id: 1,
        episode: 13,
        seasonEpisode: 1,
        type: 0,
        name: '',
        nameCn: '',
      ),
      EpisodeInfo(
        id: 2,
        episode: 14,
        seasonEpisode: 2,
        type: 0,
        name: '',
        nameCn: '',
      ),
    ]);
    final releases = [release('13', number: 13), release('14', number: 14)];
    final episodes = rssEpisodes(releases, episodeNumbers: numbers);
    expect(episodes.map((episode) => episode.number), [1, 2]);
    expect(apiEpisodePageUrl(42, episodes.first), 'monogatari://episode/42/1');
    final raw = selectRssRelease(
      releases,
      episodes.first,
      episodeNumbers: numbers,
    );
    expect(raw.episodeNumber, 13);
    expect(
      selectRssVideoFile(
        [file(0, 'Show - 13.mkv')],
        raw,
        const ApiVideoEpisode(key: '1', title: '第1话', number: 13),
      ).index,
      0,
    );
  });

  test(
    'a feed missing early episodes is never shifted by its minimum number',
    () {
      expect(rssEpisodes([release('13', number: 13)]).single.number, 13);
    },
  );
  test(
    'stable main episode identities match API history and merge batches',
    () {
      final episodes = rssEpisodes([
        release('pack', batch: [1, 2, 3]),
        release('single', number: 2),
        release('half', number: 1.5),
        release('extra', special: true),
      ]);
      expect(episodes.map((e) => e.key), [
        '1',
        '1.5',
        '2',
        '3',
        'special:sp:1',
      ]);
      expect(apiEpisodePageUrl(42, episodes[2]), 'monogatari://episode/42/2');
    },
  );
  test('unknown release never receives an invented number', () {
    expect(rssEpisodes([release('unidentified')]), isEmpty);
  });
  test(
    'single release preferred to larger batch and latest revision preferred',
    () {
      final selected = selectRssRelease([
        release('pack', batch: [1, 2], date: DateTime(2026, 10)),
        release('old', number: 2, date: DateTime(2026, 1)),
        release('revised', number: 2, date: DateTime(2026, 2)),
      ], episode);
      expect(selected.key, 'revised');
    },
  );
  test('explicit release must exist and match the requested episode', () {
    final releases = [release('one', number: 1), release('two', number: 2)];
    expect(
      () => selectRssRelease(releases, episode, releaseId: 'one'),
      throwsA(isA<RssException>()),
    );
    expect(
      () => selectRssRelease(releases, episode, releaseId: 'another-group'),
      throwsA(isA<RssException>()),
    );
    expect(selectRssRelease(releases, episode, releaseId: 'two').key, 'two');
  });
  test('batch selection finds exact video instead of archive position', () {
    final files = [
      file(0, 'Show - 03.mkv'),
      file(1, 'Show - 01.mkv'),
      file(2, '[Group] Show - 02 [1080p].mkv'),
    ];
    expect(
      selectRssVideoFile(
        files,
        release('pack', batch: [1, 2, 3]),
        episode,
      ).index,
      2,
    );
  });
  test('ambiguous batch cannot fall back to the only video', () {
    expect(
      () => selectRssVideoFile(
        [file(0, 'opaque.mkv')],
        release('pack', batch: [1, 2]),
        episode,
      ),
      throwsA(isA<RssException>()),
    );
  });
  test('single episode with opaque filename can play', () {
    expect(
      selectRssVideoFile(
        [file(0, 'opaque.mkv')],
        release('two', number: 2),
        episode,
      ).index,
      0,
    );
  });
  test('conflicting single filename cannot play the wrong episode', () {
    expect(
      () => selectRssVideoFile(
        [file(0, 'Show - 03.mkv')],
        release('two', number: 2),
        episode,
      ),
      throwsA(isA<RssException>()),
    );
  });
  test(
    'a single video explicitly named as a batch cannot masquerade as a single episode',
    () {
      expect(
        () => selectRssVideoFile(
          [file(0, 'Show [01-12].mkv')],
          release('two', number: 2),
          episode,
        ),
        throwsA(isA<RssException>()),
      );
    },
  );
  test('special release cannot play a different explicitly named special', () {
    expect(
      () => selectRssVideoFile(
        [file(0, 'Show SP02.mkv')],
        release('extra', special: true),
        const ApiVideoEpisode(key: 'rss-special:sp1', title: 'SP1'),
      ),
      throwsA(isA<RssException>()),
    );
  });
  test('samples and opening credits are never selected as the episode', () {
    final files = [
      file(0, 'sample/Show - 02.mkv'),
      file(1, 'Show NCOP02.mkv'),
      file(2, 'Show - 02.mkv'),
    ];
    expect(
      selectRssVideoFile(files, release('pack', batch: [1, 2]), episode).index,
      2,
    );
  });
  test('duplicate video encodes require an unambiguous release', () {
    expect(
      () => selectRssVideoFile(
        [file(0, 'Show - 02 [720p].mkv'), file(1, 'Show - 02 [1080p].mkv')],
        release('pack', batch: [1, 2]),
        episode,
      ),
      throwsA(isA<RssException>()),
    );
  });
  test('fractional episodes are not confused with main episodes', () {
    const half = ApiVideoEpisode(key: '2.5', title: '2.5', number: 2.5);
    final selected = selectRssVideoFile(
      [file(0, 'Show - 02.mkv'), file(1, 'Show - 02.5.mkv')],
      release('half', number: 2.5),
      half,
    );
    expect(selected.index, 1);
  });
}

class _UnusedSubscriptions extends RssSubscriptionService {
  _UnusedSubscriptions() : super(repository: MemoryRssSubscriptionRepository());
}

class _PlaybackTasks implements TorrentService {
  double? logicalNumber;
  int? openedFile;
  @override
  Future<TorrentTaskSnapshot> add(
    Uri source, {
    String? title,
    int? bangumiId,
    int? subjectId,
    double? episodeNumber,
    String? releaseKey,
    Map<String, dynamic>? subjectData,
    CancelToken? cancelToken,
  }) async {
    logicalNumber = episodeNumber;
    return TorrentTaskSnapshot(
      id: 'fixture',
      source: source,
      title: title ?? '',
      state: TorrentTaskState.paused,
      files: [file(0, 'Show - 01.mkv'), file(1, 'Show - 13.mkv')],
    );
  }

  @override
  Future<List<TorrentFileInfo>> waitForMetadata(
    String id, {
    CancelToken? cancelToken,
  }) async => [file(0, 'Show - 01.mkv'), file(1, 'Show - 13.mkv')];
  @override
  Future<TorrentPlaybackLease> openStream(
    String taskId,
    int fileIndex, {
    CancelToken? cancelToken,
    bool downloadWhilePlaying = false,
  }) async {
    openedFile = fileIndex;
    expect(downloadWhilePlaying, isFalse);
    return TorrentPlaybackLease(
      taskId: taskId,
      fileIndex: fileIndex,
      url: Uri.parse('http://127.0.0.1:1/torrent/fixture'),
      close: () async {},
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('Unexpected torrent call ${invocation.memberName}');
}
