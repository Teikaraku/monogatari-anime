import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/rss/mikan_rss_client.dart';
import 'package:kazumi/services/rss/rss_subscription_service.dart';

BangumiItem _subject(int id) =>
    BangumiItem.fromJson({'id': id, 'name': 'Test', 'rating': {}, 'tags': []});

RssSubscription _subscription(int id, {int group = 370}) => RssSubscription(
  id: 'mikan/$id/3141/$group',
  subject: _subject(id),
  show: MikanShow(
    id: 3141,
    title: 'Test',
    bangumiId: id,
    detailUri: Uri.parse('https://mikanani.me/Home/Bangumi/3141'),
  ),
  group: MikanSubtitleGroup(
    id: group,
    name: 'Group',
    feedUri: mikanGroupFeedUri(3141, group),
  ),
  createdAt: DateTime.utc(2026),
);

MikanRssClient _client() => MikanRssClient(
  transport: (uri, _) async => uri.path.startsWith('/RSS')
      ? '<rss version="2.0"><channel><title>Test</title></channel></rss>'
      : '''<p class="bangumi-title">Test</p>
      <p class="bangumi-info"><a href="https://bgm.tv/subject/1">Bangumi</a></p>
      <a class="subgroup-name subgroup-370" data-anchor="#370">Group</a>
      <a class="subgroup-name subgroup-382" data-anchor="#382">Other</a>
      <a href="/RSS/Bangumi?bangumiId=3141&amp;subgroupid=370"></a>
      <a href="/RSS/Bangumi?bangumiId=3141&amp;subgroupid=382"></a>''',
);

class _Repository extends MemoryRssSubscriptionRepository {
  bool fail = false;
  Completer<void>? entered;
  Completer<void>? gate;
  @override
  Future<void> save(RssStoredState state) async {
    if (entered != null && !entered!.isCompleted) entered!.complete();
    final pending = gate;
    if (pending != null) await pending.future;
    if (fail) throw StateError('disk full');
    await super.save(state);
  }
}

void main() {
  test('unreadable rows survive unrelated saves and a cold reopen', () async {
    final dir = await Directory.systemTemp.createTemp('rss_preserve_');
    Hive.init(dir.path);
    var box = await Hive.openBox<dynamic>('state');
    RssSubscriptionService? service;
    try {
      final unreadable = _subscription(2).toJson();
      (unreadable['subject'] as Map)['tags'] = [
        {'name': 'TV', 'count': '20'},
      ];
      final invalidBinding = _subscription(3).toJson();
      (invalidBinding['show'] as Map)['bangumiId'] = 999;
      await box.put('state', {
        'subscriptions': [
          _subscription(1).toJson(),
          unreadable,
          invalidBinding,
        ],
        'releases': [
          {'key': 'unreadable release'},
        ],
      });
      for (var pass = 0; pass < 2; pass++) {
        service = RssSubscriptionService(
          repository: HiveRssSubscriptionRepository(box: box),
        );
        await service.initialize();
        expect(service.subscriptions.map((s) => s.bangumiId), [1]);
        expect(service.lastError, '部分订阅读取失败');
        await service.markViewed(1);
        final saved = box.get('state') as Map;
        expect(saved['subscriptions'], hasLength(3));
        expect((saved['subscriptions'] as List)[1], unreadable);
        expect((saved['subscriptions'] as List)[2], invalidBinding);
        expect(saved['releases'], [
          {'key': 'unreadable release'},
        ]);
        service.dispose();
        service = null;
        await box.close();
        box = await Hive.openBox<dynamic>('state');
      }
    } finally {
      service?.dispose();
      await box.close();
      await dir.delete(recursive: true);
    }
  });

  test(
    'unreadable document blocks writes without overwriting the original',
    () async {
      final dir = await Directory.systemTemp.createTemp('rss_unreadable_');
      Hive.init(dir.path);
      final box = await Hive.openBox<dynamic>('state');
      try {
        for (final raw in [
          'bad document',
          {'subscriptions': 'bad list'},
          {'version': 2},
        ]) {
          await box.put('state', raw);
          final service = RssSubscriptionService(
            repository: HiveRssSubscriptionRepository(box: box),
          );
          await expectLater(
            service.markViewed(1),
            throwsA(isA<RssException>()),
          );
          expect(box.get('state'), raw);
          service.dispose();
        }
      } finally {
        await box.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'failed subscribe stays invisible and a later retry commits cleanly',
    () async {
      final repo = _Repository()..fail = true;
      final service = RssSubscriptionService(
        repository: repo,
        client: _client(),
      );
      addTearDown(service.dispose);
      final show = await service.getShow(3141);
      final edits = <void>[];
      final listening = service.localEdits.listen(edits.add);
      addTearDown(listening.cancel);
      await expectLater(
        service.subscribe(_subject(1), show, show.groups.first),
        throwsA(isA<RssException>()),
      );
      expect(service.subscriptions, isEmpty);
      expect(service.exportSync('local').entries, isEmpty);
      expect((await repo.load()).subscriptions, isEmpty);
      repo.fail = false;
      await service.subscribe(_subject(1), show, show.groups.first);
      await Future<void>.delayed(Duration.zero);
      expect(service.subscriptions, hasLength(1));
      expect((await repo.load()).subscriptions, hasLength(1));
      expect(edits, hasLength(1));
    },
  );

  test(
    'pending save is hidden and queued writes use the last committed state',
    () async {
      final repo = _Repository()
        ..entered = Completer<void>()
        ..gate = Completer<void>();
      final service = RssSubscriptionService(
        repository: repo,
        client: _client(),
      );
      addTearDown(service.dispose);
      final show = await service.getShow(3141);
      final first = service.subscribe(_subject(1), show, show.groups.first);
      await repo.entered!.future;
      expect(service.subscriptions, isEmpty);
      expect(service.exportSync('local').entries, isEmpty);
      final viewed = service.markViewed(1);
      repo.gate!.complete();
      await Future.wait([first, viewed]);
      final stored = await repo.load();
      expect(stored.subscriptions, hasLength(1));
      expect(stored.viewed, contains(1));
    },
  );

  for (final skew in [Duration.zero, const Duration(days: 365)]) {
    test(
      'resubscribe supersedes a known deletion with clock skew $skew',
      () async {
        final now = DateTime.utc(2026, 10, 17);
        final repo = _Repository();
        var service = RssSubscriptionService(
          repository: repo,
          client: _client(),
          clock: () => now,
        );
        final id = _subscription(1).id;
        final stale = RssSyncState(
          entries: [
            RssSyncEntry(
              id: id,
              updatedAt: now.add(skew).millisecondsSinceEpoch,
              deviceId: 'remote',
            ),
          ],
        );
        await service.mergeSyncState(stale, 'local');
        final show = await service.getShow(3141);
        await service.subscribe(_subject(1), show, show.groups.first);
        service.dispose();
        service = RssSubscriptionService(repository: repo, clock: () => now);
        addTearDown(service.dispose);
        await service.mergeSyncState(stale, 'local');
        expect(service.subscriptions.map((s) => s.id), [id]);
        expect(service.exportSync('local').entries[id]!.deleted, false);
      },
    );
  }

  test(
    'a subtitle selection supersedes an observed future timestamp',
    () async {
      final now = DateTime.utc(2026);
      final first = _subscription(1), second = _subscription(1, group: 382);
      final futureStamp = now
          .add(const Duration(days: 365))
          .millisecondsSinceEpoch;
      final repo = _Repository();
      await repo.save(
        RssStoredState(
          subscriptions: [first, second],
          selected: {1: first.id},
          selectionStamps: {
            1: (at: futureStamp, device: 'remote', deleted: false),
          },
        ),
      );
      final service = RssSubscriptionService(
        repository: repo,
        clock: () => now,
      );
      addTearDown(service.dispose);
      await service.selectSubscription(second.id);
      await service.mergeSyncState(
        RssSyncState(
          selections: [
            RssSyncSelection(
              bangumiId: 1,
              subscriptionId: first.id,
              updatedAt: futureStamp,
              deviceId: 'remote',
            ),
          ],
        ),
        'local',
      );
      expect(service.subscriptionForSubject(1)?.id, second.id);
    },
  );

  test(
    'deleting a legacy subscription supersedes its creation timestamp',
    () async {
      final now = DateTime.utc(2025);
      final repo = _Repository();
      final first = _subscription(1);
      await repo.save(RssStoredState(subscriptions: [first]));
      final service = RssSubscriptionService(
        repository: repo,
        clock: () => now,
      );
      addTearDown(service.dispose);
      await service.initialize();
      final oldCopy = service.exportSync('remote');
      await service.remove(first.id);
      expect(
        service.exportSync('local').merge(oldCopy).entries[first.id]!.deleted,
        true,
      );
    },
  );

  for (final action in [
    'remove',
    'disable',
    'select',
    'view',
    'refresh',
    'sync',
  ]) {
    test(
      'failed $action leaves the durable state and sync versions unchanged',
      () async {
        final repo = _Repository();
        final first = _subscription(1), second = _subscription(1, group: 382);
        await repo.save(
          RssStoredState(
            subscriptions: [first, second],
            selected: {1: first.id},
          ),
        );
        final service = RssSubscriptionService(
          repository: repo,
          client: _client(),
        );
        addTearDown(service.dispose);
        await service.initialize();
        final before = service.exportSync('local').encode();
        final originalSubscriptions = service.subscriptions;
        final viewed = service.newSince(1);
        repo.fail = true;
        final work = switch (action) {
          'remove' => service.remove(first.id),
          'disable' => service.setEnabled(first.id, false),
          'select' => service.selectSubscription(second.id),
          'view' => service.markViewed(1),
          'refresh' => service.refresh(),
          _ => service.mergeSyncState(
            RssSyncState(
              entries: [
                RssSyncEntry(
                  id: first.id,
                  updatedAt: DateTime.utc(2030).millisecondsSinceEpoch,
                  deviceId: 'remote',
                ),
              ],
            ),
            'local',
          ),
        };
        await expectLater(work, throwsA(isA<RssException>()));
        expect(service.exportSync('local').encode(), before);
        expect(service.newSince(1), viewed);
        expect(service.subscriptions, originalSubscriptions);
        expect(service.subscriptions.every((s) => s.lastError == null), true);
        expect((await repo.load()).subscriptions, hasLength(2));
      },
    );
  }
}
