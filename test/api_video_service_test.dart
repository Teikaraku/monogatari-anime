import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/api_video/api_video_service.dart';

BangumiItem subject({
  String name = '测试动画',
  String? chinese,
  List<String> aliases = const [],
}) => BangumiItem(
  id: 42,
  type: 2,
  name: name,
  nameCn: chinese ?? name,
  summary: '',
  airDate: '2024-01-01',
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
}) => {
  'vod_id': id,
  'vod_name': name,
  'type_name': type,
  'vod_year': '2024',
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
    'catalog uses 1080zyk4 first, is lazy and shares its cache with candidates',
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
      expect(requests.map((uri) => uri.host), ['api.yzzy-api.com']);

      final first = await service
          .candidatesForEpisode(item, catalog.episodes[1])
          .first;
      expect(first.episode.number, 2);
      expect(first.url, 'https://cdn.test/2.m3u8');
      expect(first.httpHeaders['Referer'], 'https://1080zyk4.com/');
      expect(requests, hasLength(1));
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
      expect(catalog.episodes.last.key, 'special:sp01');
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
      expect(calls.map((uri) => uri.host).toSet(), {'api.yzzy-api.com'});
      expect(calls.map((uri) => uri.path).toSet(), {'/inc/apijson.php'});
      expect(calls.map((uri) => uri.queryParameters['pg']), ['1', '2']);
      expect(calls.last.queryParameters['wd'], '测试动画');
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
          pages.add(uri.queryParameters['pg']);
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
}
