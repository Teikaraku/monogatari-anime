import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/rss/mikan_rss_client.dart';

void main() {
  test(
    'RSS switches from a removed proxy to direct without restarting',
    () async {
      var config = const NetworkConfig(proxyHost: '127.0.0.1', proxyPort: 7890);
      final configs = <NetworkConfig>[];
      final adapters = <_MikanAdapter>[];
      final client = MikanRssClient(
        networkConfig: () => config,
        createDio: (value) {
          configs.add(value);
          final adapter = _MikanAdapter();
          adapters.add(adapter);
          return Dio()..httpClientAdapter = adapter;
        },
      );
      addTearDown(client.dispose);

      expect((await client.searchShows('first')).single.id, 3141);
      await client.searchShows('same route');
      expect(adapters, hasLength(1));

      config = const NetworkConfig();
      expect((await client.searchShows('direct')).single.id, 3141);
      expect(adapters, hasLength(2));
      expect(configs.map((value) => value.hasProxy), [true, false]);
      expect(configs.every((value) => !value.enableLog), isTrue);
      expect(adapters.first.closes, [false]);

      config = const NetworkConfig(proxyHost: '127.0.0.1', proxyPort: 8890);
      await client.searchShows('new proxy');
      expect(adapters, hasLength(3));
      expect(configs.last.proxyPort, 8890);
      expect(adapters[1].closes, [false]);
    },
  );

  test(
    'changing RSS proxy does not cancel the existing in-flight request',
    () async {
      var config = const NetworkConfig(proxyHost: '127.0.0.1', proxyPort: 7890);
      final oldRequest = Completer<ResponseBody>();
      final oldStarted = Completer<void>();
      final adapters = <_MikanAdapter>[];
      final client = MikanRssClient(
        networkConfig: () => config,
        createDio: (_) {
          final adapter = _MikanAdapter(
            response: adapters.isEmpty ? oldRequest.future : null,
            started: adapters.isEmpty ? oldStarted : null,
          );
          adapters.add(adapter);
          return Dio()..httpClientAdapter = adapter;
        },
      );
      addTearDown(client.dispose);

      final pending = client.searchShows('old route');
      await oldStarted.future;
      config = const NetworkConfig();
      expect((await client.searchShows('new route')).single.id, 3141);
      expect(adapters.first.closes, [false]);
      oldRequest.complete(_searchResponse());
      expect((await pending).single.id, 3141);
    },
  );
}

ResponseBody _searchResponse() => ResponseBody.fromString(
  '<a href="/Home/Bangumi/3141"><span class="an-info">测试动画</span></a>',
  200,
);

class _MikanAdapter implements HttpClientAdapter {
  _MikanAdapter({this.response, this.started});

  final Future<ResponseBody>? response;
  final Completer<void>? started;
  final closes = <bool>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    started?.complete();
    return response == null ? _searchResponse() : await response!;
  }

  @override
  void close({bool force = false}) => closes.add(force);
}
