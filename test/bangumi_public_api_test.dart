import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/pages/timeline/timeline_controller.dart';
import 'package:kazumi/repositories/collect_repository.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/search_parser.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  late Directory directory;
  late PathProviderPlatform previous;
  late _Adapter adapter;
  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp(
      'monogatari_public_api_test_',
    );
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
    await GStorage.putSetting(SettingsKeys.bangumiAcceleration, 'direct');
  });
  setUp(() {
    DioFactory.reset();
    adapter = _Adapter();
    DioFactory.bangumiDio.httpClientAdapter.close();
    DioFactory.bangumiDio.httpClientAdapter = adapter;
  });
  tearDownAll(() async {
    DioFactory.reset();
    await Hive.close();
    PathProviderPlatform.instance = previous;
    expect(
      directory.absolute.path.startsWith(Directory.systemTemp.absolute.path),
      true,
    );
    expect(
      directory.uri.pathSegments.where((p) => p.isNotEmpty).last,
      startsWith('monogatari_public_api_test_'),
    );
    await directory.delete(recursive: true);
  });

  test(
    'chapters filter OP/ED without losing later main episodes when paging',
    () async {
      adapter.response = (request) {
        expect(request.uri.host, 'next.bgm.tv');
        expect(request.uri.path, '/p1/subjects/511936/episodes');
        final offset = int.parse(request.uri.queryParameters['offset']!);
        return offset == 0
            ? {
                'total': 4,
                'data': [
                  {'id': 1, 'sort': 1, 'type': 0, 'nameCN': '第一话'},
                  {'id': 3, 'sort': 1, 'type': 2},
                ],
              }
            : {
                'total': 4,
                'data': [
                  {'id': 2, 'sort': 2, 'type': 0, 'nameCN': '第二话'},
                  {'id': 4, 'sort': 1, 'type': 3},
                ],
              };
      };
      final episodes = await BangumiApi.getBangumiMainEpisodesByID(511936);
      expect(episodes.map((e) => e.id), [1, 2]);
      expect(episodes.map((e) => e.nameCn), ['第一话', '第二话']);
      expect(adapter.requests.last.uri.queryParameters['offset'], '2');
      expect(adapter.requests, hasLength(2));
    },
  );

  test('calendar retains shows without posters', () async {
    adapter.response = (_) => {
      for (var day = 1; day <= 7; day++)
        '$day': [
          {
            'subject': {..._subject, 'id': day, 'images': null},
          },
        ],
    };
    final days = await BangumiApi.getCalendar();
    expect(days.map((day) => day.length), List.filled(7, 1));
    expect(days.first.single.images['large'], '');
  });

  test('date and decimal score filters retain pagination without broken upstream fields', () async {
    adapter.response = (request) {
      expect(request.data['filter'].containsKey('date'), isFalse);
      expect(request.data['filter']['rating'], ['>=8', '<=9']);
      return {'total': 3, 'data': [
        _subject,
        {..._subject, 'id': 2, 'info': '12话 / 2025-10-08'},
        {..._subject, 'id': 3, 'rating': {'rank': 2, 'score': 8.1, 'total': 1}},
      ]};
    };
    final page = await BangumiApi.bangumiSearch('番剧',
      dateRange: const SearchDateRange(start: '2026-10-01', end: '2027-01-01'),
      scoreRange: const SearchDoubleRange(min: 8.2, max: 8.8));
    expect(page!.items.map((item) => item.id), [511936]);
    expect(page.rawCount, 3);
  });

  test(
    'calendar is visible while optional broadcast times are stalled',
    () async {
      final airtime = Completer<Object>();
      final metadata = _Adapter()..response = (_) => airtime.future;
      DioFactory.apiDio.httpClientAdapter.close();
      DioFactory.apiDio.httpClientAdapter = metadata;
      adapter.response = (_) => {
        for (var day = 1; day <= 7; day++)
          '$day': [
            {
              'subject': {..._subject, 'id': day},
            },
          ],
      };
      final timeline = TimelineController(CollectRepository());
      try {
        await timeline
            .loadSeason(DateTime.now())
            .timeout(const Duration(seconds: 1));
        expect(timeline.isLoading, isFalse);
        expect(timeline.isTimeOut, isFalse);
        expect(timeline.bangumiCalendar.expand((day) => day), hasLength(7));
        expect(airtime.isCompleted, isFalse);
      } finally {
        airtime.complete({'items': []});
        await Future<void>.delayed(Duration.zero);
      }
    },
  );

  test(
    'past season browses all monthly pages and parses ISO premiere dates',
    () async {
      adapter.response = (request) {
        expect(request.method, 'GET');
        expect(request.uri.path, '/p1/subjects');
        final q = request.uri.queryParameters;
        final month = int.parse(q['month']!);
        final page = int.parse(q['page']!);
        final cat = int.parse(q['cat']!);
        return {
          'total': 2,
          'data': [
            {
              ..._subject,
              'id': month * 100 + cat * 10 + page,
              'info': '12话 / 2026-${q['month']!.padLeft(2, '0')}-08 / Staff',
            },
          ],
        };
      };
      final days = await BangumiApi.getSeasonCalendar([
        '2026-07-01',
        '2026-10-01',
      ]);
      expect(adapter.requests, hasLength(12));
      expect(days.expand((day) => day), hasLength(12));
      expect(
        days.expand((day) => day).map((s) => s.airDate),
        contains('2026-08-08'),
      );
    },
  );

  test(
    'new staff endpoint follows pagination and combines positions',
    () async {
      adapter.response = (request) {
        expect(request.uri.path, '/p1/subjects/400602/staffs/persons');
        final offset = int.parse(request.uri.queryParameters['offset']!);
        return {
          'total': 2,
          'data': [
            {
              'staff': {'id': offset + 1, 'name': 'Staff', 'nameCN': '制作人员'},
              'positions': [
                {
                  'type': {'cn': '导演'},
                },
                {
                  'type': {'cn': '脚本'},
                },
              ],
            },
          ],
        };
      };
      final staff = await BangumiApi.getBangumiStaffByID(400602);
      expect(staff.data, hasLength(2));
      expect(staff.data.first.relations, ['导演', '脚本']);
      expect(staff.data.first.staff.nameCN, '制作人员');
    },
  );

  test(
    'new character and relation schemas preserve casts and relation names',
    () async {
      adapter.response = (request) => {
        'total': 1,
        'data': request.uri.path.endsWith('characters')
            ? [
                {
                  'character': {'id': 12, 'name': '角色'},
                  'type': 1,
                  'casts': [
                    {
                      'person': {'id': 13, 'name': '声优'},
                    },
                  ],
                },
              ]
            : [
                {
                  'subject': _subject,
                  'relation': {'cn': '续集'},
                },
              ],
      };
      final cast = await BangumiApi.getCharatersByBangumiID(1);
      expect(cast.charactersList.single.relation, '主角');
      expect(cast.charactersList.single.actorList.single.id, 13);
      final related = await BangumiApi.getBangumiRelationsByID(1);
      expect(related.single.relation, '续集');
      expect(related.single.bangumiItem.nameCn, '番剧');
    },
  );

  test(
    'ranking uses the live p1 search and preserves Chinese names and air dates',
    () async {
      adapter.response = (request) {
        expect(request.uri.host, 'next.bgm.tv');
        expect(request.uri.path, '/p1/search/subjects');
        expect(request.data['sort'], 'rank');
        expect(request.data['filter']['metaTags'], ['漫画改']);
        return {
          'total': 1,
          'data': [_subject],
        };
      };
      final page = await BangumiApi.bangumiSearch(
        '',
        sort: 'rank',
        tags: ['漫画改'],
      );
      expect(page!.rawCount, 1);
      expect(page.items.single.nameCn, '番剧');
      expect(page.items.single.airDate, '2026-10-08');
      expect(page.items.single.airWeekday, 4);
    },
  );

  test(
    'p1 keeps v0 season numbering across pages and skips opening numbers',
    () async {
      adapter.response = (request) {
        final offset = int.parse(request.uri.queryParameters['offset']!);
        return offset == 0
            ? {
                'total': 4,
                'data': [
                  {'id': 1, 'sort': 13, 'type': 0, 'disc': 0},
                  {'id': 3, 'sort': 1, 'type': 2, 'disc': 0},
                ],
              }
            : {
                'total': 4,
                'data': [
                  {'id': 2, 'sort': 15, 'type': 0, 'disc': 0},
                  {'id': 4, 'sort': 13.5, 'type': 0, 'disc': 0},
                ],
              };
      };
      final episodes = await BangumiApi.getBangumiMainEpisodesByID(511936);
      expect(episodes.map((e) => e.episode), [13, 15, 13.5]);
      expect(episodes.map((e) => e.displayNumber), [1, 3, 1.5]);
    },
  );

  test(
    'weekday filtering is applied without changing raw pagination count',
    () async {
      adapter.response = (_) => {
        'total': 1,
        'data': [_subject],
      };
      final page = await BangumiApi.bangumiSearch('', weekdays: [1]);
      expect(page!.items, isEmpty);
      expect(page.rawCount, 1);
    },
  );
}

const _subject = {
  'id': 511936,
  'name': 'アニメ',
  'nameCN': '番剧',
  'info': '12话 / 2026年10月8日 / 监督',
  'images': <String, String>{},
  'rating': {'rank': 1, 'score': 8.5, 'total': 1, 'count': <int>[]},
};

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  FutureOr<Object> Function(RequestOptions) response = (_) => {};
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(await response(options)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}
