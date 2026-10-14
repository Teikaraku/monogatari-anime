import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/services/rss/rss_playback_resolver.dart';
import 'package:kazumi/services/rss/rss_subscription_service.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';

void main() {
  test(
    'feed refresh and season numbering overlap, and episode switches reuse verified numbering',
    () async {
      final source = _Subscriptions()..saved = [];
      final metadata = Completer<List<EpisodeInfo>>();
      var loads = 0;
      final resolver = RssPlaybackResolver(
        source,
        _NoTorrents(),
        loadEpisodes: (_) {
          loads++;
          return metadata.future;
        },
      );
      try {
        final pending = resolver.load(42);
        await Future<void>.delayed(Duration.zero);
        expect(source.refreshes, 1);
        expect(loads, 1);
        source.saved = [_release(13)];
        source.refreshDone.complete();
        metadata.complete([
          EpisodeInfo(
            id: 1,
            episode: 13,
            seasonEpisode: 1,
            type: 0,
            name: '',
            nameCn: '',
          ),
        ]);
        expect((await pending).episodes.single.number, 1);
        source.selected = source.selected.copyWith(
          lastRefreshedAt: DateTime.now(),
        );
        expect((await resolver.load(42)).episodes.single.number, 1);
        expect(loads, 1);
      } finally {
        source.dispose();
      }
    },
  );
  late _Subscriptions subscriptions;
  late RssPlaybackResolver resolver;
  setUp(() {
    subscriptions = _Subscriptions();
    resolver = RssPlaybackResolver(subscriptions, _NoTorrents());
  });
  tearDown(() => subscriptions.dispose());

  test(
    'stale cached episodes are returned while feed request is still pending',
    () async {
      final catalog = await resolver
          .load(42)
          .timeout(const Duration(seconds: 1));
      expect(catalog.episodes.single.number, 1);
      expect(subscriptions.refreshDone.isCompleted, isFalse);
      subscriptions.saved = [_release(1), _release(2)];
      subscriptions.refreshDone.complete();
      expect(
        (await catalog.refreshed)!.episodes.map((episode) => episode.number),
        [1, 2],
      );
    },
  );

  test(
    'an empty cache waits for the feed before reporting a playable catalogue',
    () async {
      subscriptions.saved = [];
      var ready = false;
      final loading = resolver.load(42).then((catalog) {
        ready = true;
        return catalog;
      });
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);
      subscriptions.saved = [_release(2)];
      subscriptions.refreshDone.complete();
      expect((await loading).episodes.single.number, 2);
    },
  );

  test('failed feed refresh leaves cached playback usable', () async {
    final catalog = await resolver.load(42);
    subscriptions.refreshDone.completeError(StateError('network offline'));
    expect(await catalog.refreshed, isNull);
    expect(catalog.episodes.single.number, 1);
  });

  test(
    'cancelled playback cannot publish a late refreshed catalogue',
    () async {
      final token = CancelToken();
      final catalog = await resolver.load(42, cancelToken: token);
      token.cancel();
      subscriptions.saved = [_release(2)];
      subscriptions.refreshDone.complete();
      expect(await catalog.refreshed, isNull);
      expect(catalog.episodes.single.number, 1);
    },
  );

  test('refresh cannot switch the captured subtitle group', () async {
    final catalog = await resolver.load(42);
    subscriptions.selected = _subscription('other-group');
    subscriptions.saved = [_release(2)];
    subscriptions.refreshDone.complete();
    expect(await catalog.refreshed, isNull);
    expect(catalog.subscription.id, 'selected-group');
  });

  test(
    'fresh usable cache does not schedule another network refresh',
    () async {
      subscriptions.selected = subscriptions.selected.copyWith(
        lastRefreshedAt: DateTime.now(),
      );
      final catalog = await resolver.load(42);
      expect(catalog.refreshed, isNull);
      expect(subscriptions.refreshes, 0);
    },
  );
}

class _Subscriptions extends RssSubscriptionService {
  _Subscriptions() : super(repository: MemoryRssSubscriptionRepository());
  RssSubscription selected = _subscription('selected-group');
  List<RssRelease> saved = [_release(1)];
  final refreshDone = Completer<void>();
  int refreshes = 0;
  @override
  Future<void> initialize() async {}
  @override
  RssSubscription? subscriptionForSubject(int bangumiId) => selected;
  @override
  List<RssRelease> releasesForSubject(
    int bangumiId, {
    double? episodeNumber,
    String? subscriptionId,
  }) => List.of(saved);
  @override
  Future<void> refresh({String? subscriptionId, CancelToken? cancelToken}) {
    refreshes++;
    return refreshDone.future;
  }
}

class _NoTorrents implements TorrentService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('Loading an RSS catalogue must not start the torrent engine');
}

RssSubscription _subscription(String id) => RssSubscription(
  id: id,
  subject: BangumiItem(
    id: 42,
    type: 2,
    name: 'Show',
    nameCn: '番剧',
    summary: '',
    airDate: '',
    airWeekday: 0,
    rank: 0,
    images: {},
    tags: [],
    alias: [],
    ratingScore: 0,
    votes: 0,
    votesCount: [],
    info: '',
  ),
  show: MikanShow(
    id: 1,
    title: 'Show',
    detailUri: Uri.parse('https://mikanani.me/Home/Bangumi/1'),
    bangumiId: 42,
  ),
  group: MikanSubtitleGroup(
    id: 2,
    name: id,
    feedUri: Uri.parse(
      'https://mikanani.me/RSS/Bangumi?bangumiId=1&subgroupid=2',
    ),
  ),
  createdAt: DateTime(2020),
  lastRefreshedAt: DateTime(2020),
);

RssRelease _release(int number) => RssRelease(
  key: 'episode-$number',
  title: 'Show - $number',
  detailUri: Uri.parse('https://mikanani.me/Home/Episode/$number'),
  episodeNumber: number.toDouble(),
);
