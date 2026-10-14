import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/api_video/public_hls_proxy.dart';

void main() {
  test(
    'short segments prefetch concurrently, keep headers and bounded cache, and serve valid ranges',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var active = 0, peak = 0;
      final visited = <String>[];
      origin.listen((request) async {
        visited.add(request.uri.path);
        expect(request.headers.value('referer'), 'https://fixture.test/');
        if (request.uri.path == '/index.m3u8') {
          request.response.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:1\n${List.generate(5, (i) => '#EXTINF:1,\n$i.ts').join('\n')}\n#EXT-X-ENDLIST\n',
          );
        } else {
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 100));
          request.response.add([0, 1, 2, 3]);
          active--;
        }
        await request.response.close();
      });
      final relay = PublicHlsProxy(
        source: Uri.parse('http://127.0.0.1:${origin.port}/index.m3u8'),
        client: HttpClient()..maxConnectionsPerHost = 4,
        allowUri: (uri) => uri.host == '127.0.0.1' && uri.port == origin.port,
        headers: {'Referer': 'https://fixture.test/'},
        maxCacheBytes: 16,
      );
      final client = HttpClient();
      await relay.start();
      client.findProxy = (_) => 'PROXY 127.0.0.1:${relay.uri.port}';
      try {
        final manifest = await (await client.getUrl(relay.uri)).close();
        final raw = await manifest.transform(utf8.decoder).join();
        final segments = const LineSplitter()
            .convert(raw)
            .where((line) => line.startsWith('http'))
            .toList();
        final request = await client.getUrl(Uri.parse(segments.first));
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=1-2');
        final response = await request.close();
        expect(response.statusCode, 206);
        expect(
          response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 1-2/4',
        );
        expect(
          await response.fold<List<int>>(
            [],
            (out, bytes) => out..addAll(bytes),
          ),
          [1, 2],
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(peak, greaterThanOrEqualTo(2));
        expect(peak, lessThanOrEqualTo(4));
        expect(visited, containsAll(['/0.ts', '/1.ts', '/2.ts', '/3.ts']));
        expect(visited, isNot(contains('/4.ts')));
        expect(relay.cachedBytes, lessThanOrEqualTo(16));
        final reused = await (await client.getUrl(
          Uri.parse(segments[1]),
        )).close();
        await reused.drain<void>();
        expect(visited.where((path) => path == '/1.ts'), hasLength(1));
      } finally {
        await relay.close();
        client.close(force: true);
        await origin.close(force: true);
        expect(relay.cachedBytes, 0);
      }
    },
  );

  test(
    'redirected playlist resolves relative variants, keys and initialization maps from its final URL',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      origin.listen((request) async {
        paths.add(request.uri.path);
        if (request.uri.path == '/index.m3u8') {
          request.response.statusCode = 302;
          request.response.headers.set('location', '/nested/media.m3u8');
        } else if (request.uri.path.endsWith('.m3u8')) {
          request.response.write(
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXT-X-MAP:URI="init.mp4"\n#EXT-X-BYTERANGE:4@0\n#EXTINF:1,\nsegment.mp4\n#EXT-X-ENDLIST\n',
          );
        } else {
          expect(request.headers.value('range'), 'bytes=0-3');
          request.response.statusCode = 206;
          request.response.headers.set('content-range', 'bytes 0-3/16');
          request.response.add([0, 1, 2, 3]);
        }
        await request.response.close();
      });
      final relay = PublicHlsProxy(
        source: Uri.parse('http://127.0.0.1:${origin.port}/index.m3u8'),
        client: HttpClient(),
        allowUri: (uri) => uri.host == '127.0.0.1' && uri.port == origin.port,
      );
      final client = HttpClient();
      await relay.start();
      try {
        final response = await (await client.getUrl(relay.uri)).close();
        final raw = await response.transform(utf8.decoder).join();
        expect(raw, isNot(contains('URI="key.bin"')));
        expect(raw, isNot(contains('URI="init.mp4"')));
        final url = const LineSplitter()
            .convert(raw)
            .singleWhere((line) => line.startsWith('http'));
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set('range', 'bytes=0-3');
        final ranged = await request.close();
        expect(ranged.statusCode, 206);
        expect(ranged.headers.value('content-range'), 'bytes 0-3/16');
        await ranged.drain<void>();
        expect(paths, [
          '/index.m3u8',
          '/nested/media.m3u8',
          '/nested/segment.mp4',
        ]);
      } finally {
        await relay.close();
        client.close(force: true);
        await origin.close(force: true);
      }
    },
  );

  test(
    'unsafe playlist URLs are rejected before fetching and stale scopes stop working',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var hits = 0;
      origin.listen((request) async {
        hits++;
        request.response.write(
          '#EXTM3U\n#EXTINF:1,\nhttp://127.0.0.1:9/private.ts\n',
        );
        await request.response.close();
      });
      final relay = PublicHlsProxy(
        source: Uri.parse('http://127.0.0.1:${origin.port}/index.m3u8'),
        client: HttpClient(),
        allowUri: (uri) => uri.host == '127.0.0.1' && uri.port == origin.port,
      );
      final client = HttpClient();
      await relay.start();
      try {
        final response = await (await client.getUrl(relay.uri)).close();
        expect(response.statusCode, 502);
        await response.drain<void>();
        expect(hits, 1);
        final unknown = await (await client.getUrl(
          relay.uri.replace(path: '/unknown/0'),
        )).close();
        expect(unknown.statusCode, 404);
        await unknown.drain<void>();
      } finally {
        await relay.close();
        client.close(force: true);
        await origin.close(force: true);
      }
    },
  );
}
