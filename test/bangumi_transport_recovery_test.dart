import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kazumi/request/core/bangumi_transport.dart';
import 'package:kazumi/request/core/network_config.dart';

void main() {
  test('mirror DNS errors recover to the original public API and briefly avoid the failed mirror', () async {
    final fallback = _FailedAdapter();
    final visited = <Uri>[];
    final adapter = BangumiEchAdapter(fallback: fallback, config: const NetworkConfig(),
      echClient: (_) => MockClient((request) async {
        visited.add(request.url);
        return http.Response('{"data":[]}', 200);
      }),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    try {
      for (final id in [1, 2]) {
        final response = await dio.get('https://bgm.monogatari.top/v0/subjects/$id',
          options: Options(extra: {'bangumiOriginalApi': 'https://api.bgm.tv/v0/subjects/$id'}));
        expect(response.statusCode, 200);
      }
      expect(fallback.calls, 1);
      expect(visited.map((uri) => uri.host), everyElement('api.bgm.tv'));
    } finally { dio.close(force: true); }
  });

  test('authenticated requests and cancellation never cause public API fallback', () async {
    for (final cancelled in [false, true]) {
      var encrypted = 0;
      final fallback = _FailedAdapter(cancelled: cancelled);
      final dio = Dio()..httpClientAdapter = BangumiEchAdapter(
        fallback: fallback, config: const NetworkConfig(), echClient: (_) {
          encrypted++;
          return MockClient((_) async => http.Response('{}', 200));
        },
      );
      try {
        await expectLater(dio.get('https://bgm.monogatari.top/v0/me', options: Options(
          headers: cancelled ? {} : {'authorization': 'fixture'},
          extra: {'bangumiOriginalApi': 'https://api.bgm.tv/v0/me'},
        )), throwsA(isA<DioException>()));
        expect(encrypted, 0);
      } finally { dio.close(force: true); }
    }
  });
}

class _FailedAdapter implements HttpClientAdapter {
  _FailedAdapter({this.cancelled = false});
  final bool cancelled;
  var calls = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    if (cancelled) throw DioException.requestCancelled(requestOptions: options, reason: 'fixture cancelled');
    throw DioException.connectionError(requestOptions: options, reason: 'Failed host lookup');
  }
  @override
  void close({bool force = false}) {}
}
