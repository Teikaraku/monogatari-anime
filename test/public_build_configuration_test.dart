import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kazumi/request/apis/airtime_api.dart';
import 'package:kazumi/request/apis/danmaku_api.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/config/public_origins.dart';
import 'package:kazumi/services/network/bangumi_image_url_rewriter.dart';
import 'package:kazumi/services/network/mikan_http_adapter.dart';
import 'package:kazumi/services/network/public_metadata_relay.dart';

void main() {
  test('public source has no built-in private service or derived relative endpoints', () {
    expect(publicCatalogOrigin, isEmpty);
    expect(publicCatalogUri(), isNull);
    expect(ApiEndpoints.hasPublicCatalog, isFalse);
    expect(ApiEndpoints.pluginShopMirror, isEmpty);
    expect(ApiEndpoints.bangumiAirtime, isEmpty);
    expect(ApiEndpoints.latestAppMirror, isEmpty);
    expect(ApiEndpoints.dandanAPIDomain, isEmpty);
    expect(ApiEndpoints.bangumiAuthAPIMirrorDomain, 'https://api.bgm.tv');
    expect(
      ApiEndpoints.latestAppApi,
      'https://api.github.com/repos/Teikaraku/monogatari-anime/releases/latest',
    );
  });

  test('relay configuration accepts HTTP origins and rejects credentials or relative URLs', () {
    expect(
      publicCatalogUri('https://relay.example.test')?.host,
      'relay.example.test',
    );
    for (final value in [
      '',
      '//relay.example.test',
      '/relay',
      'file:///relay',
      'https://user:password@relay.example.test',
      'https://relay.example.test/?key=value',
    ]) {
      expect(publicCatalogUri(value), isNull, reason: value);
    }
  });

  test('unconfigured public metadata request never produces a relay URL', () {
    final request = RequestOptions(
      path: 'https://mikanani.me/RSS/Bangumi?bangumiId=1',
    );
    expect(publicMetadataRelayUri(request), isNull);
    expect(
      publicMetadataRelayUri(
        request,
        relayOrigin: 'https://relay.example.test',
      )?.toString(),
      'https://relay.example.test/public/mikan/RSS/Bangumi?bangumiId=1',
    );
  });

  test('unconfigured image relay retains public origin with original-size optimization', () {
    expect(
      BangumiImageUrlRewriter.rewrite(
        Uri.parse('https://lain.bgm.tv/r/200/pic/cover/l/fixture.jpg'),
      ).toString(),
      'https://lain.bgm.tv/pic/cover/l/fixture.jpg',
    );
    final api = Uri.parse('https://api.bgm.tv/v0/subjects/1/image?type=large');
    expect(BangumiImageUrlRewriter.rewrite(api), api);
  });

  test('unconfigured Mikan relay uses only its public origin', () async {
    final fallback = _NoRelayRequests();
    final requested = <Uri>[];
    final adapter = MikanHttpAdapter(
      fallback: fallback,
      proxyForUri: (_) => null,
      createEchClient: () => MockClient((request) async {
        requested.add(request.url);
        return http.Response('<rss><channel/></rss>', 200);
      }),
    );
    addTearDown(() => adapter.close(force: true));
    final response = await adapter.fetch(
      RequestOptions(path: 'https://mikanani.me/RSS/Bangumi?bangumiId=1'),
      null,
      null,
    );
    await response.stream.drain<void>();
    expect(requested.single.host, 'mikanani.me');
    expect(fallback.requests, 0);
  });

  test(
    'unconfigured broadcast supplement needs no storage or HTTP client',
    () async {
      expect(await AirtimeApi.load(), isEmpty);
    },
  );

  test(
    'unconfigured danmaku fails before storage or HTTP client access',
    () async {
      final unconfigured = isA<StateError>().having(
        (error) => error.message,
        'message',
        'Danmaku relay is not configured',
      );
      await expectLater(
        DanmakuApi.getDanDanBangumiIDByBgmBangumiID(1),
        throwsA(unconfigured),
      );
      await expectLater(
        DanmakuApi.getDanDanEpisodesByDanDanBangumiID(1),
        throwsA(unconfigured),
      );
      await expectLater(
        DanmakuApi.searchAnimes('fixture'),
        throwsA(unconfigured),
      );
      await expectLater(
        DanmakuApi.getDanDanmakuByEpisodeID(1),
        throwsA(unconfigured),
      );
    },
  );
}

class _NoRelayRequests implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    throw StateError('Unexpected relay request');
  }

  @override
  void close({bool force = false}) {}
}
