import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/storage/storage.dart';
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
  Object Function(RequestOptions) response = (_) => {};
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(response(options)),
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
