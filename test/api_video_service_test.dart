import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/api_video/api_video_service.dart';

BangumiItem subject({
  int id = 42,
  String name = '测试动画',
  String? chinese,
  List<String> aliases = const [],
  String airDate = '2024-01-01',
}) => BangumiItem(
  id: id,
  type: 2,
  name: name,
  nameCn: chinese ?? name,
  summary: '',
  airDate: airDate,
  airWeekday: 1,
  rank: 0,
  images: {},
  tags: [],
  alias: aliases,
  ratingScore: 0,
  votes: 0,
  votesCount: [],
  info: '',
);

Map<String, dynamic> row({
  String name = '测试动画',
  String id = '1',
  String? entries,
  String type = '日韩动漫',
  String from = 'm3u8',
  String year = '2024',
}) => {
  'vod_id': id,
  'vod_name': name,
  'type_name': type,
  'vod_year': year,
  'vod_play_from': from,
  'vod_play_url':
      entries ?? r'第01集$https://cdn.test/1.m3u8#第02集$https://cdn.test/2.m3u8',
};

Map<String, dynamic> document(List<Map<String, dynamic>> rows) => {
  'code': 1,
  'pagecount': 1,
  'list': rows,
};

void main() {
  test(
    'a slow spelling cannot delay an exact translated title, and loser queries are cancelled',
    () async {
      final tokens = <CancelToken>[];
      final service = ApiVideoService(
        providerPreferenceWait: Duration.zero,
        aliasHedgeDelay: const Duration(milliseconds: 10),
        transport: (uri, token) async {
          if (uri.queryParameters['wd'] == '另一译名') {
            tokens.add(token!);
            return Completer<Object?>().future;
          }
          return document([row(name: '测试动画')]);
        },
      );
      final catalog = await service
          .loadCatalog(subject(name: '测试动画', chinese: '另一译名'))
          .timeout(const Duration(milliseconds: 250));
      expect(catalog.title, '测试动画');
      await Future<void>.delayed(Duration.zero);
      expect(tokens, hasLength(3));
      expect(tokens.every((token) => token.isCancelled), isTrue);
    },
  );
  test(
    'a ready backup starts before a stalled preferred API times out',
    () async {
      final transport = _ControlledMetadata();
      final service = ApiVideoService(
        transport: transport.call,
        providerPreferenceWait: const Duration(milliseconds: 20),
      );
      final item = subject();
      final pending = service.loadCatalog(item);
      transport.requests[1].response.complete(
        document([row(id: 'ready-backup')]),
      );
      transport.requests[2].response.complete(document([]));
      final catalog = await pending.timeout(const Duration(milliseconds: 250));
      expect(catalog.provider, ApiVideoProvider.baofeng);
      final candidate = await service
          .candidatesForEpisode(item, catalog.episodes.first)
          .first
          .timeout(const Duration(milliseconds: 250));
      expect(candidate.provider, ApiVideoProvider.baofeng);
      expect(transport.requests, hasLength(3));
      expect(transport.requests.first.token.isCancelled, isFalse);
      transport.completeAll();
    },
  );
  test(
    'catalog selects 1080zyk4 first and shares prepared metadata with candidates',
    () async {
      final requests = <Uri>[];
      final service = ApiVideoService(
        transport: (uri, token) async {
          requests.add(uri);
          return document([row()]);
        },
      );
      final item = subject();
      final catalog = await service.loadCatalog(item);
      expect(catalog.provider, ApiVideoProvider.zy1080);
      expect(requests.map((uri) => uri.host), _providerHosts);

      final first = await service
          .candidatesForEpisode(item, catalog.episodes[1])
          .first;
      expect(first.episode.number, 2);
      expect(first.url, 'https://cdn.test/2.m3u8');
      expect(first.httpHeaders['Referer'], 'https://1080zyk4.com/');
      expect(requests, hasLength(3));
      expect(
        apiEpisodePageUrl(item.id, first.episode),
        'monogatari://episode/42/2',
      );
    },
  );

  test(
    'candidates progress in priority order and match numbers rather than positions',
    () async {
      final hosts = <String>[];
      final service = ApiVideoService(
        transport: (uri, token) async {
          hosts.add(uri.host);
          final code = uri.host.split('.').first;
          return document([
            row(
              entries:
                  '特典\$https://$code.test/special.m3u8#第02集\$https://$code.test/2.m3u8#第01集\$https://$code.test/1.m3u8',
            ),
          ]);
        },
      );
      const episode = ApiVideoEpisode(key: '2', title: '第2集', number: 2);
      final results = await service
          .candidatesForEpisode(subject(), episode)
          .toList();
      expect(results.map((v) => v.provider), apiVideoProviderPriority);
      expect(results.map((v) => v.url), everyElement(endsWith('/2.m3u8')));
      expect(hosts, ['api.yzzy-api.com', 'bfzyapi.com', 'cj.lziapi.com']);
    },
  );

  test(
    'parses direct lines, rejects HTML parser URLs and sorts numbered episodes',
    () async {
      final service = ApiVideoService(
        transport: (uri, token) async => document([
          row(
            from: r'parser$$$m3u8$$$backup',
            entries:
                r'第01集$https://parse.test/player?url=https://cdn.test/1.m3u8$$$第03集$https://cdn.test/3.m3u8#SP01$https://cdn.test/sp.m3u8#第01集$https://cdn.test/1.m3u8#第02集$https://cdn.test/2.m3u8$$$第01集$https://backup.test/1.mp4',
          ),
        ]),
      );
      final item = subject();
      final catalog = await service.loadCatalog(item);
      expect(catalog.episodes.map((v) => v.number), [1, 2, 3, null]);
      expect(catalog.episodes.last.key, 'special:sp:1');
      final iterator = StreamIterator(
        service.candidatesForEpisode(item, catalog.episodes.first),
      );
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current.url, 'https://cdn.test/1.m3u8');
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current.url, 'https://backup.test/1.mp4');
      await iterator.cancel();
    },
  );

  test('rejects other seasons, commentary and live-action remakes', () async {
    final service = ApiVideoService(
      transport: (uri, token) async {
        return document([
          row(name: '测试动画第二季'),
          row(name: '测试动画解说'),
          row(type: '日本剧'),
          row(id: 'correct'),
        ]);
      },
    );
    final catalog = await service.loadCatalog(subject());
    expect(catalog.id, 'correct');
  });

  test(
    'matches declared aliases and equivalent season numbers without loose substrings',
    () async {
      final service = ApiVideoService(
        transport: (uri, token) async => document([
          row(name: '夏目友人帐 第6季', id: 'wrong'),
          row(name: '夏目友人帐第7季', id: 'correct'),
        ]),
      );
      final catalog = await service.loadCatalog(
        subject(name: '夏目友人帳 漆', aliases: ['夏目友人帐 第七季']),
      );
      expect(catalog.id, 'correct');
    },
  );

  test(
    '1080zyk4 uses its JSON collection route and pages exact title results',
    () async {
      final calls = <Uri>[];
      final service = ApiVideoService(
        transport: (uri, token) async {
          calls.add(uri);
          if (uri.queryParameters['pg'] == '1') {
            return {
              ...document([row(name: '测试动画第二季', id: 'wrong')]),
              'pagecount': 2,
            };
          }
          return document([row(id: '11')]);
        },
      );
      final catalog = await service.loadCatalog(subject());
      expect(catalog.provider, ApiVideoProvider.zy1080);
      expect(catalog.id, '11');
      final primary = calls.where((uri) => uri.host == 'api.yzzy-api.com');
      expect(primary.map((uri) => uri.path).toSet(), {'/inc/apijson.php'});
      expect(primary.map((uri) => uri.queryParameters['pg']), ['1', '2']);
      expect(primary.last.queryParameters['wd'], '测试动画');
    },
  );

  test(
    'provider timeout advances to the next API rather than hanging',
    () async {
      final service = ApiVideoService(
        providerTimeout: const Duration(milliseconds: 15),
        transport: (uri, token) async {
          if (uri.host == 'api.yzzy-api.com')
            return Completer<Object?>().future;
          return document([row()]);
        },
      );
      final catalog = await service.loadCatalog(subject());
      expect(catalog.provider, ApiVideoProvider.baofeng);
    },
  );

  test('caller cancellation stops fallback requests', () async {
    final token = CancelToken();
    final calls = <Uri>[];
    final service = ApiVideoService(
      transport: (uri, callerToken) async {
        calls.add(uri);
        token.cancel('changed episode');
        return document([row()]);
      },
    );
    await expectLater(
      service.loadCatalog(subject(), cancelToken: token),
      throwsA(isA<DioException>()),
    );
    expect(calls, hasLength(1));
  });

  test(
    'single movie labels and fractional episode numbers keep stable keys',
    () async {
      final service = ApiVideoService(
        transport: (uri, token) async =>
            document([row(entries: r'HD中字$https://cdn.test/movie.m3u8')]),
      );
      final movie = await service.loadCatalog(subject());
      expect(movie.episodes.single.number, 1);
      expect(movie.episodes.single.key, '1');
      final fractional = ApiVideoService(
        transport: (uri, token) async => document([
          row(
            entries:
                r'第12.5集$https://cdn.test/12_5.m3u8#第十二集$https://cdn.test/12.m3u8',
          ),
        ]),
      );
      final catalog = await fractional.loadCatalog(subject());
      expect(catalog.episodes.map((v) => v.number), [12, 12.5]);
      expect(catalog.episodes.last.key, '12.5');
    },
  );

  test(
    'successful cache expires so newly released episodes are visible',
    () async {
      var now = DateTime(2026);
      var calls = 0;
      final service = ApiVideoService(
        clock: () => now,
        cacheTtl: const Duration(seconds: 1),
        transport: (uri, token) async {
          calls++;
          return document([
            row(entries: calls == 1 ? r'第01集$https://cdn.test/1.m3u8' : null),
          ]);
        },
      );
      expect((await service.loadCatalog(subject())).episodes, hasLength(1));
      now = now.add(const Duration(seconds: 2));
      expect((await service.loadCatalog(subject())).episodes, hasLength(2));
    },
  );

  test(
    'background expansion adds fallback episodes without shifting existing indexes',
    () async {
      final service = ApiVideoService(
        transport: (uri, token) async {
          return document([
            row(
              entries: uri.host == 'api.yzzy-api.com'
                  ? r'第01集$https://bf.test/1.m3u8#第03集$https://bf.test/3.m3u8'
                  : r'第04集$https://backup.test/4.m3u8#第02集$https://backup.test/2.m3u8#第01集$https://backup.test/1.m3u8',
            ),
          ]);
        },
      );
      final item = subject();
      final initial = await service.loadCatalog(item);
      expect(initial.episodes.map((episode) => episode.key), ['1', '3']);
      final updates = await service.expandedEpisodes(item, initial).toList();
      expect(updates, hasLength(1));
      expect(updates.single.map((episode) => episode.key), [
        '1',
        '3',
        '2',
        '4',
      ]);
      expect(updates.single[1], same(initial.episodes[1]));
    },
  );

  test(
    'missing selected episode skips the provider without selecting its first episode',
    () async {
      final service = ApiVideoService(
        transport: (uri, token) async {
          return document([
            row(
              entries: uri.host == 'api.yzzy-api.com'
                  ? r'第01集$https://bf.test/1.m3u8'
                  : r'第02集$https://backup.test/2.m3u8',
            ),
          ]);
        },
      );
      const desired = ApiVideoEpisode(key: '2', title: '第2集', number: 2);
      final candidate = await service
          .candidatesForEpisode(subject(), desired)
          .first;
      expect(candidate.provider, ApiVideoProvider.baofeng);
      expect(candidate.episode.number, 2);
    },
  );

  test(
    'the same CDN URL can be retried with another provider referer',
    () async {
      final service = ApiVideoService(
        transport: (uri, token) async {
          return document([row(entries: r'第01集$https://same.test/1.m3u8')]);
        },
      );
      const desired = ApiVideoEpisode(key: '1', title: '第1集', number: 1);
      final results = await service
          .candidatesForEpisode(subject(), desired)
          .toList();
      expect(
        results.map((candidate) => candidate.provider),
        apiVideoProviderPriority,
      );
      expect(
        results.map((candidate) => candidate.httpHeaders['Referer']).toSet(),
        hasLength(3),
      );
    },
  );

  test(
    'temporary API failure is cached briefly and can recover after expiration',
    () async {
      var now = DateTime(2026);
      var primaryCalls = 0;
      final service = ApiVideoService(
        clock: () => now,
        transport: (uri, token) async {
          if (uri.host == 'api.yzzy-api.com') {
            primaryCalls++;
            if (primaryCalls == 1) throw StateError('API 404');
            return document([row()]);
          }
          return document([row()]);
        },
      );
      final item = subject();
      expect(
        (await service.loadCatalog(item)).provider,
        ApiVideoProvider.baofeng,
      );
      expect(
        (await service.loadCatalog(item)).provider,
        ApiVideoProvider.baofeng,
      );
      expect(primaryCalls, 1);
      now = now.add(const Duration(seconds: 16));
      expect(
        (await service.loadCatalog(item)).provider,
        ApiVideoProvider.zy1080,
      );
      expect(primaryCalls, 2);
    },
  );

  test(
    'a matching parser-only result does not hide playable results on later pages',
    () async {
      final pages = <String?>[];
      final service = ApiVideoService(
        transport: (uri, token) async {
          if (uri.host == 'api.yzzy-api.com') {
            pages.add(uri.queryParameters['pg']);
          }
          if (uri.queryParameters['pg'] == '1') {
            return {
              ...document([
                row(
                  entries:
                      r'第01集$https://parser.test/watch?url=https://cdn.test/1.m3u8',
                ),
              ]),
              'pagecount': 2,
            };
          }
          return document([row(id: 'playable')]);
        },
      );
      final catalog = await service.loadCatalog(subject());
      expect(catalog.id, 'playable');
      expect(pages, ['1', '2']);
    },
  );

  test(
    'clearing cache rejects late cache writes from a previous request',
    () async {
      final oldResponse = Completer<Object?>();
      final oldStarted = Completer<void>();
      var requests = 0;
      final service = ApiVideoService(
        transport: (uri, token) async {
          if (uri.host != 'api.yzzy-api.com') return document([row()]);
          requests++;
          if (requests == 1) {
            oldStarted.complete();
            return oldResponse.future;
          }
          return document([row(entries: r'第01集$https://fresh.test/1.m3u8')]);
        },
      );
      final item = subject();
      final previous = service.loadCatalog(item);
      await oldStarted.future;
      service.clearCache();
      final current = await service.loadCatalog(item);
      oldResponse.complete(
        document([row(entries: r'第01集$https://stale.test/1.m3u8')]),
      );
      await previous;
      final candidate = await service
          .candidatesForEpisode(item, current.episodes.first)
          .first;
      expect(candidate.url, 'https://fresh.test/1.m3u8');
      expect(requests, 2);
    },
  );

  test('unlistened candidate streams perform no requests', () {
    final transport = _ControlledMetadata();
    final service = ApiVideoService(transport: transport.call);
    service.candidatesForEpisode(
      subject(),
      const ApiVideoEpisode(key: '1', title: '第1集', number: 1),
    );
    expect(transport.requests, isEmpty);
  });

  test(
    'prefetch prepares three JSON APIs without requesting playlists or media',
    () async {
      final transport = _ControlledMetadata();
      final service = ApiVideoService(transport: transport.call);
      final item = subject();
      final warmup = service.prefetchCatalog(item);
      expect(
        transport.requests.map((request) => request.uri.host),
        _providerHosts,
      );
      expect(
        transport.requests.map((request) => request.uri.queryParameters['ac']),
        everyElement('detail'),
      );
      expect(
        transport.requests.map((request) => request.uri.path),
        everyElement(isNot(endsWith('.m3u8'))),
      );
      transport.completeAll();
      await warmup;
      final catalog = await service.loadCatalog(item);
      await service.expandedEpisodes(item, catalog).toList();
      await service.candidatesForEpisode(item, catalog.episodes.first).first;
      expect(transport.requests, hasLength(3));
    },
  );

  test(
    'fallback warmup survives the early catalog result and is shared by expansion and playback',
    () async {
      final transport = _ControlledMetadata();
      final service = ApiVideoService(transport: transport.call);
      final item = subject();
      final catalogFuture = service.loadCatalog(item);
      transport.requests.first.response.complete(
        document([row(entries: r'第01集$https://primary.test/1.m3u8')]),
      );
      final catalog = await catalogFuture;
      expect(
        transport.requests.skip(1).map((request) => request.token.isCancelled),
        everyElement(isFalse),
      );
      final expansion = service.expandedEpisodes(item, catalog).toList();
      final playback = service
          .candidatesForEpisode(
            item,
            const ApiVideoEpisode(key: '2', title: '第2集', number: 2),
          )
          .first;
      await _flushEvents();
      expect(transport.requests, hasLength(3));
      transport.requests[2].response.complete(
        document([row(entries: r'第03集$https://third.test/3.m3u8')]),
      );
      transport.requests[1].response.complete(
        document([row(entries: r'第02集$https://second.test/2.m3u8')]),
      );
      expect((await playback).provider, ApiVideoProvider.baofeng);
      expect((await expansion).last.map((episode) => episode.key), [
        '1',
        '2',
        '3',
      ]);
      expect(transport.requests, hasLength(3));
    },
  );

  test(
    'cancelling one consumer leaves shared requests and their successful cache intact',
    () async {
      final transport = _ControlledMetadata();
      final service = ApiVideoService(transport: transport.call);
      final cancelled = CancelToken();
      final interested = CancelToken();
      final first = service.prefetchCatalog(subject(), cancelToken: cancelled);
      final firstResult = expectLater(first, throwsA(isA<DioException>()));
      final second = service.prefetchCatalog(
        subject(),
        cancelToken: interested,
      );
      expect(transport.requests, hasLength(3));
      cancelled.cancel('detail page left');
      await firstResult;
      expect(
        transport.requests.map((request) => request.token.isCancelled),
        everyElement(isFalse),
      );
      transport.completeAll();
      await second;
      expect(
        (await service.loadCatalog(subject())).provider,
        ApiVideoProvider.zy1080,
      );
      expect(transport.requests, hasLength(3));
    },
  );

  test(
    'last consumer cancellation aborts all flights without poisoning the next attempt',
    () async {
      final transport = _ControlledMetadata();
      final service = ApiVideoService(transport: transport.call);
      final firstToken = CancelToken();
      final secondToken = CancelToken();
      final first = expectLater(
        service.prefetchCatalog(subject(), cancelToken: firstToken),
        throwsA(isA<DioException>()),
      );
      final second = expectLater(
        service.prefetchCatalog(subject(), cancelToken: secondToken),
        throwsA(isA<DioException>()),
      );
      firstToken.cancel('left');
      secondToken.cancel('left');
      await Future.wait([first, second]);
      expect(
        transport.requests.map((request) => request.token.isCancelled),
        everyElement(isTrue),
      );
      final retry = service.prefetchCatalog(subject());
      expect(transport.requests, hasLength(6));
      transport.completeAll();
      await retry;
      expect(
        (await service.loadCatalog(subject())).provider,
        ApiVideoProvider.zy1080,
      );
      expect(transport.requests, hasLength(6));
    },
  );

  test(
    'stream cancellation releases leases immediately even while awaiting metadata',
    () async {
      final transport = _ControlledMetadata();
      final service = ApiVideoService(transport: transport.call);
      final subscription = service
          .candidatesForEpisode(
            subject(),
            const ApiVideoEpisode(key: '1', title: '第1集', number: 1),
          )
          .listen((_) {});
      await _flushEvents();
      expect(transport.requests, hasLength(3));
      await subscription.cancel().timeout(const Duration(seconds: 1));
      expect(
        transport.requests.map((request) => request.token.isCancelled),
        everyElement(isTrue),
      );
      final retry = service.prefetchCatalog(subject());
      expect(transport.requests, hasLength(6));
      transport.completeAll();
      await retry;
    },
  );

  test(
    'caller cancellation is still reported to an active candidate listener',
    () async {
      final transport = _ControlledMetadata();
      final service = ApiVideoService(transport: transport.call);
      final token = CancelToken();
      final cancelled = expectLater(
        service
            .candidatesForEpisode(
              subject(),
              const ApiVideoEpisode(key: '1', title: '第1集', number: 1),
              cancelToken: token,
            )
            .toList(),
        throwsA(isA<DioException>()),
      );
      await _flushEvents();
      token.cancel('changed episode');
      await cancelled;
      expect(
        transport.requests.map((request) => request.token.isCancelled),
        everyElement(isTrue),
      );
    },
  );

  test(
    'cancelling a waiting stream leaves another operation interested in its shared flights',
    () async {
      final transport = _ControlledMetadata();
      final service = ApiVideoService(transport: transport.call);
      final warmup = service.prefetchCatalog(subject());
      final subscription = service
          .candidatesForEpisode(
            subject(),
            const ApiVideoEpisode(key: '1', title: '第1集', number: 1),
          )
          .listen((_) {});
      await _flushEvents();
      await subscription.cancel().timeout(const Duration(seconds: 1));
      expect(transport.requests, hasLength(3));
      expect(
        transport.requests.map((request) => request.token.isCancelled),
        everyElement(isFalse),
      );
      transport.completeAll();
      await warmup;
      expect(
        (await service.loadCatalog(subject())).provider,
        ApiVideoProvider.zy1080,
      );
      expect(transport.requests, hasLength(3));
    },
  );

  test(
    'faster lower-priority responses cannot win catalog or candidate selection',
    () async {
      final transport = _ControlledMetadata();
      final service = ApiVideoService(transport: transport.call);
      var catalogCompleted = false;
      final catalogFuture = service.loadCatalog(subject()).then((value) {
        catalogCompleted = true;
        return value;
      });
      transport.requests[2].response.complete(document([row(id: 'third')]));
      transport.requests[1].response.complete(document([row(id: 'second')]));
      await _flushEvents();
      expect(catalogCompleted, isFalse);
      transport.requests[0].response.complete(document([row(id: 'first')]));
      final catalog = await catalogFuture;
      expect(catalog.provider, ApiVideoProvider.zy1080);
      final candidates = await service
          .candidatesForEpisode(subject(), catalog.episodes.first)
          .toList();
      expect(
        candidates.map((candidate) => candidate.provider),
        apiVideoProviderPriority,
      );
      expect(candidates.map((candidate) => candidate.id), [
        'first',
        'second',
        'third',
      ]);
    },
  );

  test(
    'all source timeout budgets begin together rather than after previous failures',
    () async {
      final started = <Uri>[];
      final startedCountsAtTimeout = <int>[];
      final service = ApiVideoService(
        providerTimeout: const Duration(milliseconds: 30),
        transport: (uri, token) {
          started.add(uri);
          unawaited(
            token!.whenCancel.then((_) {
              startedCountsAtTimeout.add(started.length);
            }),
          );
          return Completer<Object?>().future;
        },
      );
      await expectLater(
        service.loadCatalog(subject()),
        throwsA(isA<ApiVideoUnavailableException>()),
      );
      expect(started.map((uri) => uri.host), _providerHosts);
      expect(startedCountsAtTimeout, [3, 3, 3]);
    },
  );

  test(
    'clearCache separates generations without stale writes or removing fresh shared flights',
    () async {
      final transport = _ControlledMetadata();
      final service = ApiVideoService(transport: transport.call);
      final oldWarmup = service.prefetchCatalog(subject());
      service.clearCache();
      final freshWarmup = service.prefetchCatalog(subject());
      expect(transport.requests, hasLength(6));
      for (final request in transport.requests.take(3)) {
        request.response.complete(document([row(id: 'stale')]));
      }
      await oldWarmup;
      final current = service.loadCatalog(subject());
      expect(transport.requests, hasLength(6));
      for (final request in transport.requests.skip(3)) {
        request.response.complete(document([row(id: 'fresh')]));
      }
      await freshWarmup;
      expect((await current).id, 'fresh');
      expect((await service.loadCatalog(subject())).id, 'fresh');
      expect(transport.requests, hasLength(6));
    },
  );

  test(
    'matching snapshots the mutable subject year and separates cache keys',
    () async {
      final transport = _ControlledMetadata();
      final service = ApiVideoService(transport: transport.call);
      final item = subject();
      final old = service.prefetchCatalog(item);
      item.airDate = '2025-01-01';
      final fresh = service.prefetchCatalog(item);
      expect(transport.requests, hasLength(6));
      for (final request in transport.requests) {
        request.response.complete(
          document([
            row(id: '2025', year: '2025'),
            row(id: '2024', year: '2024'),
          ]),
        );
      }
      await Future.wait([old, fresh]);
      expect((await service.loadCatalog(item)).id, '2025');
      item.airDate = '2024-01-01';
      expect((await service.loadCatalog(item)).id, '2024');
      expect(transport.requests, hasLength(6));
    },
  );

  test(
    'different capped keyword order cannot share a negative cache entry',
    () async {
      final queried = <String>[];
      final service = ApiVideoService(
        transport: (uri, token) async {
          final keyword = uri.queryParameters['wd']!;
          queried.add(keyword);
          return document(keyword == '别名六' ? [row(id: 'found')] : []);
        },
      );
      final aliases = ['别名一', '别名二', '别名三', '别名四', '别名五', '别名六'];
      await service.prefetchCatalog(subject(aliases: aliases));
      expect(queried, isNot(contains('别名六')));
      await expectLater(
        service.loadCatalog(subject(aliases: aliases)),
        throwsA(isA<ApiVideoUnavailableException>()),
      );
      final catalog = await service.loadCatalog(
        subject(aliases: aliases.reversed.toList()),
      );
      expect(catalog.id, 'found');
      expect(catalog.provider, ApiVideoProvider.zy1080);
      expect(queried, contains('别名六'));
    },
  );

  test(
    'completed metadata cache is bounded and evicts the least recently used subject',
    () async {
      final calls = <String, int>{};
      final service = ApiVideoService(
        maxCachedProviders: 6,
        transport: (uri, token) async {
          final name = uri.queryParameters['wd']!;
          calls.update(name, (value) => value + 1, ifAbsent: () => 1);
          return document([row(name: name)]);
        },
      );
      final first = subject(id: 1, name: '动画1');
      final second = subject(id: 2, name: '动画2');
      final third = subject(id: 3, name: '动画3');
      await service.prefetchCatalog(first);
      await service.prefetchCatalog(second);
      await service.loadCatalog(first);
      await service.prefetchCatalog(third);
      await service.prefetchCatalog(first);
      expect(calls['动画1'], 3);
      await service.prefetchCatalog(second);
      expect(calls['动画2'], 6);
    },
  );
}

const _providerHosts = ['api.yzzy-api.com', 'bfzyapi.com', 'cj.lziapi.com'];

Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);

class _MetadataRequest {
  _MetadataRequest(this.uri, this.token);
  final Uri uri;
  final CancelToken token;
  final response = Completer<Object?>();
}

class _ControlledMetadata {
  final requests = <_MetadataRequest>[];

  Future<Object?> call(Uri uri, CancelToken? token) {
    final request = _MetadataRequest(uri, token!);
    requests.add(request);
    return request.response.future;
  }

  void completeAll() {
    for (final request in requests) {
      if (!request.response.isCompleted) {
        request.response.complete(document([row()]));
      }
    }
  }
}
