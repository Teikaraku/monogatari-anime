import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kazumi/request/core/bangumi_transport.dart';
import 'package:kazumi/request/core/network_config.dart';

void main() {
  test(
    'large calendar JSON validates in a worker without capturing requests',
    () async {
      final document = {
        for (var day = 1; day <= 7; day++)
          '$day': [
            {
              'subject': {'id': day, 'name': '番剧' * 5000},
            },
          ],
      };
      final body = jsonEncode(document);
      expect(utf8.encode(body).length, greaterThan(64 * 1024));
      final dio = _publicDio(
        _CallbackAdapter(
          (options, stream, cancel) async => ResponseBody.fromString(
            body,
            200,
            headers: {
              'content-type': ['application/json'],
            },
          ),
        ),
        MockClient((_) async => http.Response('{}', 200)),
      );
      try {
        final response = await dio.get(
          'https://bgm.monogatari.top/p1/calendar',
          options: Options(
            extra: {'bangumiOriginalApi': 'https://next.bgm.tv/p1/calendar'},
          ),
        );
        expect(response.data, document);
      } finally {
        dio.close(force: true);
      }
    },
  );

  test('public requests race the mirror and original API', () async {
    final fallback = _FailedAdapter();
    final visited = <Uri>[];
    final adapter = BangumiEchAdapter(fallback: fallback, config: const NetworkConfig(),
      echClient: (_) => MockClient((request) async {
        visited.add(request.url);
        return http.Response('{"id":1}', 200);
      }),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    try {
      for (final id in [1, 2]) {
        final response = await dio.get('https://bgm.monogatari.top/v0/subjects/$id',
          options: Options(extra: {'bangumiOriginalApi': 'https://api.bgm.tv/v0/subjects/$id'}));
        expect(response.statusCode, 200);
      }
      expect(fallback.calls, 2);
      expect(visited.map((uri) => uri.host), everyElement('api.bgm.tv'));
    } finally { dio.close(force: true); }
  });

  test(
    'a stalled mirror does not delay a complete official document',
    () async {
      final mirrorStarted = Completer<void>();
      final mirrorCancelled = Completer<void>();
      final fallback = _CallbackAdapter((options, stream, cancel) async {
        mirrorStarted.complete();
        cancel!.then((_) => mirrorCancelled.complete());
        return Completer<ResponseBody>().future;
      });
      final dio = _publicDio(
        fallback,
        MockClient((request) async {
          await mirrorStarted.future;
          return http.Response(
            '{"id":1,"winner":"official"}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      try {
        final response = await dio
            .get(_mirror, options: _publicOptions)
            .timeout(const Duration(seconds: 1));
        expect(response.data['winner'], 'official');
        await mirrorCancelled.future.timeout(const Duration(seconds: 1));
      } finally {
        dio.close(force: true);
      }
    },
  );

  test('a mirror with fast headers and a stuck body cannot win', () async {
    final body = StreamController<Uint8List>();
    final cancelled = Completer<void>();
    body.onCancel = () {
      if (!cancelled.isCompleted) cancelled.complete();
    };
    final dio = _publicDio(
      _CallbackAdapter((options, stream, cancel) async {
        cancel!.then((_) => body.close());
        return ResponseBody(
          body.stream,
          200,
          headers: {
            'content-type': ['application/json'],
          },
        );
      }),
      MockClient(
        (_) async => http.Response(
          '{"id":1,"ok":true}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    try {
      final result = await dio
          .get(_mirror, options: _publicOptions)
          .timeout(const Duration(seconds: 1));
      expect(result.data['ok'], isTrue);
      await cancelled.future.timeout(const Duration(seconds: 1));
    } finally {
      dio.close(force: true);
      await body.close();
    }
  });

  for (final status in [200, 403, 429, 503]) {
    test(
      'HTTP $status error pages cannot hide a valid official result',
      () async {
        final dio = _publicDio(
          _CallbackAdapter(
            (options, stream, cancel) async =>
                ResponseBody.fromString('<html>unavailable</html>', status),
          ),
          MockClient(
            (_) async => http.Response(
              '{"id":1,"ok":true}',
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        try {
          expect(
            (await dio.get(_mirror, options: _publicOptions)).data['ok'],
            true,
          );
        } finally {
          dio.close(force: true);
        }
      },
    );
  }

  test(
    'read-only search POST replays exactly the same serialized body',
    () async {
      String? mirrorBody;
      String? officialBody;
      final dio = _publicDio(
        _CallbackAdapter((options, stream, cancel) async {
          mirrorBody = utf8.decode(
            await stream!.expand((bytes) => bytes).toList(),
          );
          return ResponseBody.fromString('blocked', 403);
        }),
        MockClient((request) async {
          officialBody = request.body;
          return http.Response('{"data":[],"total":0}', 200);
        }),
      );
      try {
        await dio.post(
          'https://bgm.monogatari.top/p1/search/subjects',
          data: {'keyword': '葬送的芙莉莲'},
          options: Options(
            extra: {
              'bangumiOriginalApi': 'https://next.bgm.tv/p1/search/subjects',
            },
          ),
        );
        expect(mirrorBody, officialBody);
        expect(jsonDecode(officialBody!)['keyword'], '葬送的芙莉莲');
      } finally {
        dio.close(force: true);
      }
    },
  );

  test('caller cancellation terminates both routes', () async {
    final started = Completer<void>();
    final token = CancelToken();
    final dio = _publicDio(
      _CallbackAdapter((options, stream, cancel) async {
        started.complete();
        await cancel;
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: 'cancelled',
        );
      }),
      MockClient((_) => Completer<http.Response>().future),
    );
    try {
      final pending = dio.get(
        _mirror,
        options: _publicOptions,
        cancelToken: token,
      );
      final assertion = expectLater(
        pending,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await started.future;
      token.cancel();
      await assertion.timeout(const Duration(seconds: 1));
    } finally {
      dio.close(force: true);
    }
  });

  test('a JSON error document cannot win over catalog data', () async {
    final dio = _publicDio(
      _CallbackAdapter((options, stream, cancel) async =>
          ResponseBody.fromString('{"error":"unavailable"}', 200)),
      MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return http.Response('{"id":1,"ok":true}', 200,
            headers: {'content-type': 'application/json'});
      }),
    );
    try {
      expect((await dio.get(_mirror, options: _publicOptions)).data['ok'], true);
    } finally {
      dio.close(force: true);
    }
  });

  test('closing the adapter forcefully cancels an unfinished race', () async {
    final started = Completer<void>();
    final dio = _publicDio(
      _CallbackAdapter((options, stream, cancel) async {
        started.complete();
        await cancel;
        throw DioException.requestCancelled(
          requestOptions: options, reason: 'adapter closed');
      }),
      MockClient((_) => Completer<http.Response>().future),
    );
    final assertion = expectLater(
      dio.get(_mirror, options: _publicOptions),
      throwsA(isA<DioException>().having(
          (e) => e.type, 'type', DioExceptionType.cancel)),
    );
    await started.future;
    dio.close(force: true);
    await assertion.timeout(const Duration(seconds: 1));
  });

  test(
    'authenticated requests and cancellation never cause public API fallback',
    () async {
      for (final cancelled in [false, true]) {
        var encrypted = 0;
        final fallback = _FailedAdapter(cancelled: cancelled);
        final dio = Dio()
          ..httpClientAdapter = BangumiEchAdapter(
            fallback: fallback,
            config: const NetworkConfig(),
            echClient: (_) {
              encrypted++;
              return MockClient((_) async => http.Response('{}', 200));
            },
          );
        try {
          await expectLater(
            dio.get(
              'https://bgm.monogatari.top/v0/me',
              options: Options(
                headers: cancelled ? {} : {'authorization': 'fixture'},
                extra: {'bangumiOriginalApi': 'https://api.bgm.tv/v0/me'},
              ),
            ),
            throwsA(isA<DioException>()),
          );
          expect(encrypted, 0);
        } finally {
          dio.close(force: true);
        }
      }
    },
  );
}

const _mirror = 'https://bgm.monogatari.top/p1/subjects/1';
final _publicOptions = Options(
  extra: {'bangumiOriginalApi': 'https://next.bgm.tv/p1/subjects/1'},
);
Dio _publicDio(HttpClientAdapter fallback, http.Client client) => Dio()
  ..httpClientAdapter = BangumiEchAdapter(
    fallback: fallback,
    config: const NetworkConfig(),
    echClient: (_) => client,
  );

class _CallbackAdapter implements HttpClientAdapter {
  _CallbackAdapter(this.callback);
  final Future<ResponseBody> Function(
    RequestOptions,
    Stream<Uint8List>?,
    Future<void>?,
  )
  callback;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) => callback(options, stream, cancel);
  @override
  void close({bool force = false}) {}
}

class _FailedAdapter implements HttpClientAdapter {
  _FailedAdapter({this.cancelled = false});
  final bool cancelled;
  var calls = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    if (cancelled) {
      throw DioException.requestCancelled(
        requestOptions: options,
        reason: 'fixture cancelled',
      );
    }
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'Failed host lookup',
    );
  }

  @override
  void close({bool force = false}) {}
}
