import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/public_metadata_relay.dart';

RequestOptions request(String path, {Map<String, dynamic>? headers}) =>
    RequestOptions(path: path, headers: headers);
ResponseBody body(String value, [int status = 200]) => ResponseBody.fromString(
  value,
  status,
  headers: {
    'content-type': ['application/json'],
  },
);

void main() {
  const vod = 'https://bfzyapi.com/api.php/provide/vod/?ac=detail&wd=test&pg=1';
  test('only fixed public read requests can reach the relay', () {
    expect(publicMetadataRelayUri(request(vod))?.path, '/public/vod/baofeng');
    expect(
      publicMetadataRelayUri(
        request(
          'https://mikanani.me/RSS/Bangumi?bangumiId=4062&subgroupid=583',
        ),
      )?.path,
      '/public/mikan/RSS/Bangumi',
    );
    expect(
      publicMetadataRelayUri(
        request(
          'https://mikanani.me/RSS/Bangumi?subgroupid=583&bangumiId=4062',
        ),
      )?.query,
      'bangumiId=4062&subgroupid=583',
    );
    for (final url in [
      'https://mikanani.me/RSS/MyBangumi?token=secret',
      'https://mikanani.me/RSS/Bangumi?bangumiId=1&token=secret',
      'https://mikanani.me/RSS/Bangumi?bangumiId=1&bangumiId=2',
      'https://mikanani.me/Home/Search?searchstr=a&callback=secret',
      'https://cdn.test/movie.m3u8',
      'https://private.test/RSS/Bangumi?bangumiId=1',
      'http://bfzyapi.com/api.php/provide/vod/?ac=detail',
      'https://bfzyapi.com/api.php/provide/vod/?ac=delete',
    ]) {
      expect(publicMetadataRelayUri(request(url)), isNull, reason: url);
    }
    expect(
      publicMetadataRelayUri(request(vod, headers: {'Cookie': 'secret'})),
      isNull,
    );
    expect(
      publicMetadataRelayUri(
        request(vod, headers: {'Authorization': 'secret'}),
      ),
      isNull,
    );
    expect(
      publicMetadataRelayUri(RequestOptions(path: vod, method: 'POST')),
      isNull,
    );
  });

  test(
    'a fast gateway error or challenge page cannot defeat valid data',
    () async {
      for (final bad in [
        body('bad gateway', 502),
        body('<html>challenge</html>'),
        body('{"code":0,"list":[]}'),
      ]) {
        final result = await racePublicMetadata(
          request: request(vod),
          maxBytes: 1024,
          origin: (_) async => bad,
          relay: (_) async {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return body('{"list":[]}');
          },
        );
        expect(jsonDecode(await utf8.decoder.bind(result.stream).join()), {
          'list': [],
        });
      }
    },
  );

  test('winner cancels a stalled route', () async {
    final aborted = Completer<void>();
    await racePublicMetadata(
      request: request(vod),
      maxBytes: 1024,
      origin: (cancel) async {
        await cancel;
        aborted.complete();
        throw StateError('aborted');
      },
      relay: (_) async => body('{"list":[]}'),
    );
    await aborted.future.timeout(const Duration(seconds: 1));
  });

  test('cancelling the caller promptly stops both routes', () async {
    final cancel = Completer<void>();
    var stopped = 0;
    Future<ResponseBody> stalled(Future<void> abort) async {
      await abort;
      stopped++;
      throw StateError('aborted');
    }

    final result = racePublicMetadata(
      request: request(vod),
      maxBytes: 1024,
      origin: stalled,
      relay: stalled,
      cancelFuture: cancel.future,
    );
    final assertion = expectLater(
      result,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    cancel.complete();
    await assertion;
    expect(stopped, 2);
  });

  test('response size cap is enforced while reading', () async {
    Future<ResponseBody> oversized(Future<void> _) async => ResponseBody(
      Stream<List<int>>.value(
        List.filled(2000, 32),
      ).map((bytes) => utf8.encode(String.fromCharCodes(bytes))),
      200,
    );
    await expectLater(
      racePublicMetadata(
        request: request(vod),
        maxBytes: 1024,
        origin: oversized,
        relay: oversized,
      ),
      throwsFormatException,
    );
  });

  test(
    'large bodies validate in a worker without capturing native context',
    () async {
      final text = jsonEncode({'list': [], 'padding': 'x' * (150 * 1024)});
      final result = await racePublicMetadata(
        request: request(vod),
        maxBytes: 1024 * 1024,
        origin: (_) async => body(text),
        relay: (_) async => body('bad', 502),
      );
      expect(await utf8.decoder.bind(result.stream).join(), text);
    },
  );
}
