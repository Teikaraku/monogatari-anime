import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/services/rss/mikan_rss_client.dart';
import 'package:kazumi/services/rss/rss_refresh_coordinator.dart';
import 'package:kazumi/services/rss/rss_subscription_service.dart';

void main() {
  test(
    'search extracts decoded official show cards and does not trust a matching title on another host',
    () {
      final shows = parseMikanSearch('''
      <a href="/Home/Bangumi/3141"><span class="an-info">测试 &amp; 动画</span></a>
      <a href="/Home/Bangumi/3141"><span class="an-info">duplicate</span></a>
      <a href="https://evil.test/Home/Bangumi/3142"><span class="an-info">测试动画</span></a>
    ''');
      expect(shows.map((value) => value.id), [3141]);
      expect(shows.single.title, '测试 & 动画');
      expect(shows.single.bangumiId, isNull);
    },
  );

  test(
    'show groups use RSS subgroupid rather than the different PublishGroup id',
    () {
      final show = parseMikanShow(_showHtml(), 3141);
      expect(show.bangumiId, 400602);
      expect(show.groups.first.id, 370);
      expect(show.groups.first.name, 'LoliHouse');
      expect(show.groups.first.feedUri.queryParameters['subgroupid'], '370');
      expect(show.groups.map((value) => value.id), [370, 382]);
    },
  );

  test('ambiguous official Bangumi links do not produce a verified identity', () {
    final source = _showHtml().replaceFirst(
      '</p>',
      '</p><p class="bangumi-info"><a href="https://bgm.tv/subject/123">different</a></p>',
    );
    expect(parseMikanShow(source, 3141).bangumiId, isNull);
  });

  test(
    'namespaced torrent date and size are parsed, duplicate false GUID titles use episode links',
    () {
      final uri = mikanGroupFeedUri(3141, 370);
      final feed = parseMikanFeed(
        _feedXml().replaceFirst('</channel>', '${_itemXml()}</channel>'),
        uri,
      );
      expect(feed.releases, hasLength(1));
      final release = feed.releases.single;
      expect(release.episodeNumber, 3);
      expect(release.quality, '1080p');
      expect(release.group, 'Group');
      expect(release.sizeBytes, 550502400);
      expect(release.publishedAt, DateTime.utc(2026, 10, 13, 5, 48, 19));
      expect(release.sourceUri.path, endsWith('.torrent'));
    },
  );

  test(
    'foreign enclosures, HTML challenge pages and DTD declarations are not RSS media',
    () {
      final uri = mikanGroupFeedUri(3141, 370);
      expect(
        parseMikanFeed(
          _feedXml().replaceAll(
            'https://mikanani.me/Download/',
            'https://evil.test/Download/',
          ),
          uri,
        ).releases,
        isEmpty,
      );
      expect(
        () => parseMikanFeed('<html>challenge</html>', uri),
        throwsA(isA<RssException>()),
      );
      expect(
        () => parseMikanFeed(
          '<!DOCTYPE rss [<!ENTITY secret SYSTEM "file:///secret">]><rss/>',
          uri,
        ),
        throwsA(isA<RssException>()),
      );
    },
  );

  test(
    'valid magnet enclosures are preserved, malformed hashes are discarded',
    () {
      final magnet = 'magnet:?xt=urn:btih:${'a' * 40}';
      final xml = _feedXml().replaceAll(
        RegExp(r'url="[^"]+\.torrent"'),
        'url="$magnet"',
      );
      expect(
        parseMikanFeed(
          xml,
          mikanGroupFeedUri(3141, 370),
        ).releases.single.sourceUri.scheme,
        'magnet',
      );
      expect(
        parseMikanFeed(
          xml.replaceFirst('a' * 40, 'bad'),
          mikanGroupFeedUri(3141, 370),
        ).releases,
        isEmpty,
      );
    },
  );

  test(
    'HTTP torrent metadata is preferred when a release also has a magnet',
    () {
      final hash = 'a' * 40;
      final torrent = Uri.parse(
        'https://mikanani.me/Download/20261013/$hash.torrent',
      );
      final magnet = Uri.parse('magnet:?xt=urn:btih:$hash');
      RssRelease release({Uri? torrentUri}) => RssRelease(
        key: hash,
        title: 'Test',
        detailUri: Uri.parse('https://mikanani.me/Home/Episode/$hash'),
        torrentUri: torrentUri,
        magnetUri: magnet,
      );
      expect(release(torrentUri: torrent).sourceUri, torrent);
      expect(release().sourceUri, magnet);
    },
  );

  test(
    'release parser recognizes single revisions, fractional episodes and plain filenames',
    () {
      for (final title in [
        '[Group] Test - 03v2 [1080p]',
        '[Group] Test [03][BDRip 1080p]',
        '[Group] SPY x FAMILY [03][1080p]',
        'Test_S02E03.mkv',
        '03.mkv',
        '[03].mkv',
      ]) {
        final value = parseRssReleaseTitle(title);
        expect(value.episodeNumber, 3, reason: title);
        expect(value.isBatch, isFalse, reason: title);
      }
      expect(
        parseRssReleaseTitle('[Group] Test [12.5][720p]').episodeNumber,
        12.5,
      );
    },
  );

  test(
    'date, resolution, years and codecs cannot become episodes or batch ranges',
    () {
      for (final title in [
        '[Group] Test 2026-10-12 [1080p HEVC-10bit]',
        '[Group] Test [1920x1080 x265 AAC]',
        '[Group] Test 2024 BDRip',
        '[Group] Test [720p]',
      ]) {
        final value = parseRssReleaseTitle(title);
        expect(value.episodeNumber, isNull, reason: title);
        expect(value.episodeNumbers, isEmpty, reason: title);
        expect(value.isBatch, isFalse, reason: title);
      }
    },
  );

  test('explicit main ranges and special ranges cannot be confused', () {
    final batch = parseRssReleaseTitle('[Group] Test [01-28 修正合集][1080p]+SP11');
    expect(
      batch.episodeNumbers,
      List.generate(28, (index) => (index + 1).toDouble()),
    );
    expect(batch.isSpecial, isFalse);
    expect(
      parseRssReleaseTitle('[01-28 修正合集][1080p]').episodeNumbers,
      batch.episodeNumbers,
    );
    for (final title in [
      '[Group] Test [SP01-03]',
      '[SP01-03].mkv',
      '[Group] Test SP [01-03]',
      'Test_S00E03.mkv',
    ]) {
      final special = parseRssReleaseTitle(title);
      expect(special.isSpecial, isTrue, reason: title);
      expect(special.episodeNumbers, isEmpty, reason: title);
      expect(special.episodeNumber, isNull, reason: title);
    }
    final unknown = parseRssReleaseTitle('[Group] Test 全集 [1080p]');
    expect(unknown.isBatch, isTrue);
    expect(unknown.episodeNumbers, isEmpty);
  });

  test(
    'foreign RSS and duplicate identity query parameters never bind a group',
    () {
      expect(
        isMikanFeedUri(Uri.parse('http://mikanani.me/RSS/Bangumi?bangumiId=1')),
        isFalse,
      );
      expect(
        isMikanFeedUri(Uri.parse('https://mikanani.me.evil.test/RSS/Bangumi')),
        isFalse,
      );
      expect(
        isMikanFeedUri(
          Uri.parse('https://user:secret@mikanani.me/RSS/Bangumi'),
        ),
        isFalse,
      );
      expect(
        mikanFeedId(
          Uri.parse('https://mikanani.me/RSS/Bangumi?bangumiId=1&BangumiId=2'),
          'bangumiId',
        ),
        isNull,
      );
    },
  );

  test(
    'API failures redact imported account tokens and raw exception URLs',
    () async {
      final uri = Uri.parse(
        'https://mikanani.me/RSS/MyBangumi?token=private-feed-secret',
      );
      final client = MikanRssClient(
        transport: (uri, token) async => throw StateError(uri.toString()),
      );
      await expectLater(
        client.previewFeed(uri),
        throwsA(
          isA<RssException>().having(
            (error) => error.toString(),
            'safe message',
            isNot(contains('private-feed-secret')),
          ),
        ),
      );
    },
  );

  test(
    'mapping rejects a same-title different season and uses the official linked Bangumi ID',
    () async {
      final client = MikanRssClient(
        transport: (uri, token) async {
          if (uri.path == '/Home/Search') {
            return '<a href="/Home/Bangumi/999"><span class="an-info">测试动画</span></a><a href="/Home/Bangumi/3141"><span class="an-info">测试动画</span></a>';
          }
          return _showHtml(
            bangumiId: uri.path.endsWith('/999') ? 515759 : 400602,
          );
        },
      );
      expect((await client.resolveSubject(_subject()))?.id, 3141);
    },
  );

  test(
    'cancelled mapping cannot return a previously cached verified show',
    () async {
      final client = _client();
      await client.getShow(3141);
      final token = CancelToken()..cancel('left page');
      await expectLater(
        client.resolveSubject(_subject(), cancelToken: token),
        throwsA(isA<DioException>()),
      );
      client.dispose();
    },
  );

  test(
    'large official HTML and XML responses parse through isolate workers',
    () async {
      final padding = ' ' * (128 * 1024);
      final client = MikanRssClient(
        transport: (uri, _) async {
          if (uri.path == '/Home/Search') {
            return '$padding<a href="/Home/Bangumi/3141"><span class="an-info">测试动画</span></a>';
          }
          return '$padding${uri.path.startsWith('/RSS') ? _feedXml() : _showHtml()}';
        },
      );
      expect((await client.searchShows('测试动画')).single.id, 3141);
      expect((await client.getShow(3141)).bangumiId, 400602);
      expect(
        (await client.previewFeed(
          mikanGroupFeedUri(3141, 370),
        )).releases.single.episodeNumber,
        3,
      );
      client.dispose();
    },
  );

  test(
    'initialization is read-only and retries after repository load failure',
    () async {
      final repository = _RetryRepository();
      var requests = 0;
      final service = RssSubscriptionService(
        client: MikanRssClient(
          transport: (_, _) async {
            requests++;
            return _showHtml();
          },
        ),
        repository: repository,
      );
      await expectLater(service.initialize(), throwsStateError);
      await service.initialize();
      expect(repository.loads, 2);
      expect(requests, 0);
      expect(service.subscriptions, isEmpty);
      service.dispose();
    },
  );

  test(
    'subscription persists verified IDs and exclusively uses the selected group feed',
    () async {
      final repository = MemoryRssSubscriptionRepository();
      final requests = <Uri>[];
      final client = _client(requests: requests);
      final service = RssSubscriptionService(
        client: client,
        repository: repository,
      );
      final show = await service.getShow(3141);
      final subscription = await service.subscribe(
        _subject(),
        show,
        show.groups.first,
      );
      expect(subscription.subtitleGroupId, 370);
      expect(
        requests
            .where((uri) => uri.path.startsWith('/RSS'))
            .map((uri) => uri.queryParameters['subgroupid']),
        ['370'],
      );
      expect(
        service
            .releasesForSubject(400602, episodeNumber: 3)
            .single
            .subtitleGroupId,
        370,
      );
      expect(service.releasesForSubject(400602, episodeNumber: 4), isEmpty);
      final restored = RssSubscriptionService(
        client: _client(),
        repository: repository,
      );
      await restored.initialize();
      expect(restored.subscriptionForSubject(400602)?.id, subscription.id);
      expect(
        restored.releasesForSubject(400602).single.sourceUri,
        service.releases.single.sourceUri,
      );
      service.dispose();
      restored.dispose();
    },
  );

  test(
    'multiple subscriptions require explicit selection and disabling/removing never switches groups',
    () async {
      final service = RssSubscriptionService(
        client: _client(),
        repository: MemoryRssSubscriptionRepository(),
      );
      final show = await service.getShow(3141);
      final first = await service.subscribe(
        _subject(),
        show,
        show.groups.first,
      );
      final second = await service.subscribe(
        _subject(),
        show,
        show.groups.last,
      );
      expect(service.subscriptionForSubject(400602)?.id, second.id);
      expect(
        service
            .releasesForSubject(400602)
            .every((release) => release.subtitleGroupId == 382),
        isTrue,
      );
      expect(
        service
            .releasesForSubject(400602, subscriptionId: first.id)
            .single
            .subtitleGroupId,
        370,
      );
      await service.selectSubscription(first.id);
      expect(service.releasesForSubject(400602).single.subtitleGroupId, 370);
      await service.setEnabled(first.id, false);
      expect(service.subscriptionForSubject(400602), isNull);
      expect(service.releasesForSubject(400602), isEmpty);
      await service.setEnabled(second.id, true);
      await service.remove(second.id);
      expect(service.subscriptionForSubject(400602), isNull);
      service.dispose();
    },
  );

  test(
    'subscription rejects wrong Bangumi mapping and an unselected generic feed',
    () async {
      final service = RssSubscriptionService(
        client: _client(),
        repository: MemoryRssSubscriptionRepository(),
      );
      final show = await service.getShow(3141);
      await expectLater(
        service.subscribe(_subject(id: 515759), show, show.groups.first),
        throwsA(isA<RssException>()),
      );
      await expectLater(
        service.subscribeFeed(
          _subject(),
          Uri.parse('https://mikanani.me/RSS/Bangumi?bangumiId=3141'),
        ),
        throwsA(isA<RssException>()),
      );
      expect(service.subscriptions, isEmpty);
      service.dispose();
    },
  );

  test(
    'cancelled subscription does not create or persist a partial binding',
    () async {
      final pending = Completer<String>();
      final started = Completer<void>();
      final repository = MemoryRssSubscriptionRepository();
      final client = MikanRssClient(
        transport: (uri, token) async {
          if (uri.path.startsWith('/RSS')) {
            started.complete();
            return pending.future;
          }
          return _showHtml();
        },
      );
      final service = RssSubscriptionService(
        client: client,
        repository: repository,
      );
      final show = await service.getShow(3141);
      final token = CancelToken();
      final result = expectLater(
        service.subscribe(
          _subject(),
          show,
          show.groups.first,
          cancelToken: token,
        ),
        throwsA(isA<DioException>()),
      );
      await started.future;
      token.cancel('left page');
      await result;
      expect(service.subscriptions, isEmpty);
      expect((await repository.load()).subscriptions, isEmpty);
      expect(service.lastError, isNull);
      service.dispose();
    },
  );

  test('a removed subscription is not resurrected by a late refresh', () async {
    Completer<String>? pending;
    final service = RssSubscriptionService(
      client: MikanRssClient(
        transport: (uri, token) async {
          if (!uri.path.startsWith('/RSS')) return _showHtml();
          return pending == null ? _feedXml() : await pending.future;
        },
      ),
      repository: MemoryRssSubscriptionRepository(),
    );
    final show = await service.getShow(3141);
    final subscription = await service.subscribe(
      _subject(),
      show,
      show.groups.first,
    );
    pending = Completer<String>();
    final refresh = service.refresh(subscriptionId: subscription.id);
    await Future<void>.delayed(Duration.zero);
    await service.remove(subscription.id);
    pending.complete(_feedXml());
    await refresh;
    expect(service.subscriptions, isEmpty);
    expect(service.releases, isEmpty);
    service.dispose();
  });

  test(
    'a failed refresh preserves cached releases with a safe subscription error',
    () async {
      var fail = false;
      final service = RssSubscriptionService(
        client: MikanRssClient(
          transport: (uri, _) async {
            if (!uri.path.startsWith('/RSS')) return _showHtml();
            if (fail) throw StateError('https://mikanani.me/RSS?token=secret');
            return _feedXml();
          },
        ),
        repository: MemoryRssSubscriptionRepository(),
      );
      final show = await service.getShow(3141);
      final subscription = await service.subscribe(
        _subject(),
        show,
        show.groups.first,
      );
      fail = true;
      await service.refresh(subscriptionId: subscription.id);
      expect(service.releasesForSubject(400602).single.episodeNumber, 3);
      expect(
        service.subscriptionForSubject(400602)?.lastError,
        isNot(contains('secret')),
      );
      expect(service.subscriptionForSubject(400602)?.lastError, isNotNull);
      service.dispose();
    },
  );

  test(
    'persisted official-host paths still require verified torrent and episode routes',
    () async {
      final repository = MemoryRssSubscriptionRepository();
      final service = RssSubscriptionService(
        client: _client(),
        repository: repository,
      );
      final show = await service.getShow(3141);
      final subscription = await service.subscribe(
        _subject(),
        show,
        show.groups.first,
      );
      final state = (await repository.load()).toJson();
      final release = Map<String, dynamic>.from(
        (state['releases'] as List).single as Map,
      );
      release['torrentUri'] = 'https://mikanani.me/Home/NotATorrent';
      state['releases'] = [release];
      await repository.save(RssStoredState.fromJson(state));
      final restored = RssSubscriptionService(
        client: _client(),
        repository: repository,
      );
      await restored.initialize();
      expect(restored.subscriptionForSubject(400602)?.id, subscription.id);
      expect(restored.releasesForSubject(400602), isEmpty);
      service.dispose();
      restored.dispose();
    },
  );

  test(
    'a later refresh wins even if an earlier refresh returns after it',
    () async {
      final pending = <Completer<String>>[];
      var defer = false;
      final service = RssSubscriptionService(
        client: MikanRssClient(
          transport: (uri, token) {
            if (!uri.path.startsWith('/RSS')) return Future.value(_showHtml());
            if (!defer) return Future.value(_feedXml());
            final next = Completer<String>();
            pending.add(next);
            return next.future;
          },
        ),
        repository: MemoryRssSubscriptionRepository(),
      );
      final show = await service.getShow(3141);
      final subscription = await service.subscribe(
        _subject(),
        show,
        show.groups.first,
      );
      defer = true;
      final old = service.refresh(subscriptionId: subscription.id);
      await Future<void>.delayed(Duration.zero);
      final fresh = service.refresh(subscriptionId: subscription.id);
      await Future<void>.delayed(Duration.zero);
      pending[1].complete(_feedXml(title: '[Group] Test [04][1080p]'));
      await fresh;
      pending[0].complete(_feedXml(title: '[Group] Test [02][1080p]'));
      await old;
      expect(service.releasesForSubject(400602).single.episodeNumber, 4);
      service.dispose();
    },
  );

  test('a routine refresh reads the show page only once a day', () async {
    var now = DateTime(2026, 10, 13, 12);
    final requests = <Uri>[];
    final service = RssSubscriptionService(
      client: MikanRssClient(
        transport: (uri, _) async {
          requests.add(uri);
          return uri.path.startsWith('/RSS') ? _feedXml() : _showHtml();
        },
        clock: () => now,
      ),
      repository: MemoryRssSubscriptionRepository(),
      clock: () => now,
    );
    final show = await service.getShow(3141);
    final subscription = await service.subscribe(
      _subject(),
      show,
      show.groups.first,
    );
    // Past the client's five-minute page cache, within the daily check.
    now = now.add(const Duration(minutes: 10));
    requests.clear();
    await service.refresh(subscriptionId: subscription.id);
    expect(requests.map((uri) => uri.path), ['/RSS/Bangumi']);
    now = now.add(const Duration(hours: 25));
    requests.clear();
    await service.refresh(subscriptionId: subscription.id);
    expect(requests.map((uri) => uri.path), [
      '/Home/Bangumi/3141',
      '/RSS/Bangumi',
    ]);
    service.dispose();
  });

  test('a changed show mapping asks for a new subscription', () async {
    var now = DateTime(2026, 10, 13, 12);
    var bangumiId = 400602;
    final service = RssSubscriptionService(
      client: MikanRssClient(
        transport: (uri, _) async => uri.path.startsWith('/RSS')
            ? _feedXml()
            : _showHtml(bangumiId: bangumiId),
        clock: () => now,
      ),
      repository: MemoryRssSubscriptionRepository(),
      clock: () => now,
    );
    final show = await service.getShow(3141);
    final subscription = await service.subscribe(
      _subject(),
      show,
      show.groups.first,
    );
    bangumiId = 1;
    now = now.add(const Duration(hours: 25));
    await service.refresh(subscriptionId: subscription.id);
    expect(service.subscriptions.single.lastError, contains('重新订阅'));
    expect(service.lastError, isNull);
    service.dispose();
  });

  test('resuming a paused group keeps the group picked for playback', () async {
    final service = RssSubscriptionService(
      client: _client(),
      repository: MemoryRssSubscriptionRepository(),
    );
    final show = await service.getShow(3141);
    final first = await service.subscribe(_subject(), show, show.groups.first);
    final second = await service.subscribe(_subject(), show, show.groups.last);
    await service.setEnabled(first.id, false);
    await service.setEnabled(first.id, true);
    expect(service.subscriptionForSubject(400602)?.id, second.id);
    // With nothing usable picked, resuming a group picks it.
    await service.setEnabled(second.id, false);
    await service.setEnabled(first.id, false);
    await service.setEnabled(first.id, true);
    expect(service.subscriptionForSubject(400602)?.id, first.id);
    service.dispose();
  });

  test('releases count as new until the show is opened', () async {
    var now = DateTime.utc(2026, 10, 13);
    final repository = MemoryRssSubscriptionRepository();
    final service = RssSubscriptionService(
      client: _client(),
      repository: repository,
      clock: () => now,
    );
    final show = await service.getShow(3141);
    await service.subscribe(_subject(), show, show.groups.first);
    expect(service.newReleaseCount(400602), 1);
    now = DateTime.utc(2026, 10, 14);
    await service.markViewed(400602);
    expect(service.newReleaseCount(400602), 0);
    final restored = RssSubscriptionService(
      client: _client(),
      repository: repository,
    );
    await restored.initialize();
    expect(restored.newSince(400602), DateTime.utc(2026, 10, 14));
    expect(restored.newReleaseCount(400602), 0);
    service.dispose();
    restored.dispose();
  });

  test('a show without a Mikan match is not searched again soon', () async {
    final requests = <Uri>[];
    final client = MikanRssClient(
      transport: (uri, _) async {
        requests.add(uri);
        return '<html></html>';
      },
    );
    expect(await client.resolveSubject(_subject()), isNull);
    final searched = requests.length;
    expect(searched, greaterThan(0));
    expect(await client.resolveSubject(_subject()), isNull);
    expect(requests, hasLength(searched));
    client.dispose();
  });

  group('RSS sync', () {
    final deviceA = 'a' * 32, deviceB = 'b' * 32;
    var now = DateTime.utc(2026, 10, 13, 12);
    RssSubscriptionService device() => RssSubscriptionService(
      client: _client(),
      repository: MemoryRssSubscriptionRepository(),
      clock: () => now,
    );

    test('a subscription and its removal reach the other device', () async {
      final a = device(), b = device();
      final show = await a.getShow(3141);
      final subscription = await a.subscribe(
        _subject(),
        show,
        show.groups.first,
      );
      final published = RssSyncState.decode(a.exportSync(deviceA).encode());
      await b.mergeSyncState(published, deviceB);
      expect(b.subscriptions.single.id, subscription.id);
      expect(b.subscriptionForSubject(400602)?.id, subscription.id);

      now = now.add(const Duration(minutes: 5));
      await b.remove(subscription.id);
      final removal = b.exportSync(deviceB);
      await a.mergeSyncState(removal, deviceA);
      expect(a.subscriptions, isEmpty);
      // The stale copy published earlier cannot bring it back.
      await b.mergeSyncState(published, deviceB);
      expect(b.subscriptions, isEmpty);
      a.dispose();
      b.dispose();
    });

    test('the later playback pick wins on both devices', () async {
      final a = device(), b = device();
      final show = await a.getShow(3141);
      final first = await a.subscribe(_subject(), show, show.groups.first);
      final second = await a.subscribe(_subject(), show, show.groups.last);
      await b.mergeSyncState(a.exportSync(deviceA), deviceB);
      now = now.add(const Duration(minutes: 1));
      await a.selectSubscription(first.id);
      now = now.add(const Duration(minutes: 1));
      await b.selectSubscription(second.id);
      final merged = await a.mergeSyncState(b.exportSync(deviceB), deviceA);
      await b.mergeSyncState(merged, deviceB);
      expect(a.subscriptionForSubject(400602)?.id, second.id);
      expect(b.subscriptionForSubject(400602)?.id, second.id);
      a.dispose();
      b.dispose();
    });

    test('local edits are announced for sync, refreshes are not', () async {
      final a = device();
      final edits = <void>[];
      final listening = a.localEdits.listen(edits.add);
      final show = await a.getShow(3141);
      final subscription = await a.subscribe(
        _subject(),
        show,
        show.groups.first,
      );
      await a.refresh(subscriptionId: subscription.id);
      await a.markViewed(400602);
      await Future<void>.delayed(Duration.zero);
      expect(edits, hasLength(1));
      await a.setEnabled(subscription.id, false);
      await Future<void>.delayed(Duration.zero);
      expect(edits, hasLength(2));
      await listening.cancel();
      a.dispose();
    });
  });

  test(
    'repository roundtrip is JSON maps and ignores only malformed records',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'monogatari_rss_repository_',
      );
      Hive.init(directory.path);
      final box = await Hive.openBox<dynamic>('rss_test_state');
      try {
        final repository = HiveRssSubscriptionRepository(box: box);
        final service = RssSubscriptionService(
          client: _client(),
          repository: repository,
        );
        final show = await service.getShow(3141);
        final subscription = await service.subscribe(
          _subject(),
          show,
          show.groups.first,
        );
        final stored = Map<String, dynamic>.from(box.get('state') as Map);
        (stored['subscriptions'] as List).add({'id': 'broken'});
        await box.put('state', stored);
        final restored = await repository.load();
        expect(restored.subscriptions.single.id, subscription.id);
        expect(restored.selected[400602], subscription.id);
        expect(restored.releases.single.episodeNumber, 3);
        service.dispose();
      } finally {
        await box.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'tagged subscriptions survive a cold Hive reopen and failed refresh',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'rss_cold_reopen_',
      );
      Hive.init(directory.path);
      var box = await Hive.openBox<dynamic>('rss_cold_state');
      RssSubscriptionService? service;
      try {
        service = RssSubscriptionService(
          client: _client(),
          repository: HiveRssSubscriptionRepository(box: box),
        );
        final subject = _subject()
          ..tags = [BangumiTag(name: '动画', count: 20, totalCount: 30)];
        final show = await service.getShow(3141);
        final subscription = await service.subscribe(
          subject,
          show,
          show.groups.first,
        );
        await service.markViewed(subject.id);
        service.dispose();
        service = null;
        await box.close();

        // Reading the still-open Hive box only tests its in-memory values.
        // A real restart decodes nested maps from disk without String key types.
        for (var restart = 0; restart < 2; restart++) {
          box = await Hive.openBox<dynamic>('rss_cold_state');
          service = RssSubscriptionService(
            client: MikanRssClient(
              transport: (_, _) async => throw const RssException('离线'),
            ),
            repository: HiveRssSubscriptionRepository(box: box),
          );
          await service.initialize();
          expect(service.subscriptions.map((s) => s.id), [subscription.id]);
          expect(service.subscriptions.single.subject.tags.single.name, '动画');
          expect(
            service.subscriptionForSubject(subject.id)?.id,
            subscription.id,
          );
          expect(service.releasesForSubject(subject.id), hasLength(1));
          await service.refresh();
          expect(service.subscriptions.single.lastError, isNotNull);
          expect(service.releasesForSubject(subject.id), hasLength(1));
          service.dispose();
          service = null;
          await box.close();
        }
      } finally {
        service?.dispose();
        if (box.isOpen) await box.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'foreground coordinator is opt-in, respects due time and stops in the background',
    () async {
      var now = DateTime(2026);
      var enabled = true;
      var refreshes = 0;
      final coordinator = RssRefreshCoordinator(
        refresh: (_) async {
          refreshes++;
        },
        hasEnabledSubscriptions: () => enabled,
        clock: () => now,
        observeAppLifecycle: false,
      );
      await coordinator.refreshIfDue();
      expect(refreshes, 0);
      coordinator.start();
      await Future<void>.delayed(Duration.zero);
      expect(refreshes, 1);
      now = now.add(const Duration(minutes: 10));
      await coordinator.refreshIfDue();
      expect(refreshes, 1);
      coordinator.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 20));
      await coordinator.refreshIfDue();
      expect(refreshes, 1);
      coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(refreshes, 2);
      enabled = false;
      now = now.add(const Duration(minutes: 20));
      await coordinator.refreshIfDue();
      expect(refreshes, 2);
      coordinator.dispose();
    },
  );

  test(
    'background cancels an active automatic refresh and resume can retry immediately',
    () async {
      final requests = <CancelToken>[];
      final coordinator = RssRefreshCoordinator(
        refresh: (token) {
          requests.add(token);
          return token.whenCancel.then((_) {});
        },
        hasEnabledSubscriptions: () => true,
        observeAppLifecycle: false,
      );
      coordinator.start();
      expect(requests, hasLength(1));
      coordinator.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(requests.first.isCancelled, isTrue);
      coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(requests, hasLength(2));
      coordinator.dispose();
      expect(requests.last.isCancelled, isTrue);
      await Future<void>.delayed(Duration.zero);
    },
  );
}

class _RetryRepository implements RssSubscriptionRepository {
  int loads = 0;
  @override
  Future<RssStoredState> load() async {
    if (++loads == 1) throw StateError('storage temporarily unavailable');
    return const RssStoredState();
  }

  @override
  Future<void> save(RssStoredState state) async {}
}

BangumiItem _subject({int id = 400602}) => BangumiItem(
  id: id,
  type: 2,
  name: 'Test',
  nameCn: '测试动画',
  summary: '',
  airDate: '2023-09-29',
  airWeekday: 5,
  rank: 0,
  images: {},
  tags: [],
  alias: [],
  ratingScore: 0,
  votes: 0,
  votesCount: [],
  info: '',
);

MikanRssClient _client({List<Uri>? requests}) => MikanRssClient(
  transport: (uri, token) async {
    requests?.add(uri);
    return uri.path.startsWith('/RSS') ? _feedXml() : _showHtml();
  },
);

String _showHtml({int bangumiId = 400602}) =>
    '''
<p class="bangumi-title">测试动画<a href="/RSS/Bangumi?bangumiId=3141"></a></p>
<p class="bangumi-info">Bangumi番组计划链接：<a href="https://bgm.tv/subject/$bangumiId">Bangumi</a></p>
<a class="subgroup-name subgroup-370" data-anchor="#370">LoliHouse</a>
<a class="subgroup-name subgroup-382" data-anchor="#382">另一个字幕组</a>
<a href="/Home/PublishGroup/223">LoliHouse</a>
<a href="/RSS/Bangumi?bangumiId=3141&amp;subgroupid=370"></a>
<a href="/RSS/Bangumi?bangumiId=3141&amp;subgroupid=382"></a>
''';

String _feedXml({String title = '[Group] Test [03][1080p]'}) =>
    '<rss version="2.0"><channel><title>Mikan Project - Test</title>${_itemXml(title: title)}</channel></rss>';

String _itemXml({String title = '[Group] Test [03][1080p]'}) =>
    '''
<item><guid isPermaLink="false">$title</guid><title>$title</title>
<link>https://mikanani.me/Home/Episode/${'a' * 40}</link>
<torrent xmlns="https://mikanani.me/0.1/"><contentLength>550502400</contentLength><pubDate>2026-10-13T13:48:19</pubDate></torrent>
<enclosure type="application/x-bittorrent" length="550502400" url="https://mikanani.me/Download/20261013/${'a' * 40}.torrent"/>
</item>''';
