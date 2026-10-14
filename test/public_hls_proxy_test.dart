import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/api_video/public_hls_proxy.dart';

void main() {
  test(
    'a bounded seek range finishes before unrelated segment bytes arrive and leaves the shared fetch usable',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final finish = Completer<void>();
      final payload = List.generate(128 * 1024, (i) => i & 255);
      var fetches = 0;
      origin.listen((request) async {
        if (request.uri.path.endsWith('.m3u8')) {
          request.response.write(
            '#EXTM3U\n#EXTINF:10,\n0.ts\n#EXT-X-ENDLIST\n',
          );
        } else {
          fetches++;
          request.response.contentLength = payload.length;
          request.response.add(payload.sublist(0, 64 * 1024));
          await request.response.flush();
          await finish.future;
          request.response.add(payload.sublist(64 * 1024));
        }
        try {
          await request.response.close();
        } catch (_) {}
      });
      final relay = PublicHlsProxy(
        source: Uri.parse('http://127.0.0.1:${origin.port}/index.m3u8'),
        client: HttpClient(),
        allowUri: (uri) => uri.host == '127.0.0.1' && uri.port == origin.port,
      );
      final client = HttpClient();
      await relay.start();
      try {
        final manifest = await (await (await client.getUrl(
          relay.uri,
        )).close()).transform(utf8.decoder).join();
        final uri = Uri.parse(
          const LineSplitter()
              .convert(manifest)
              .firstWhere((line) => line.startsWith('http')),
        );
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=123-4095');
        final response = await request.close().timeout(
          const Duration(seconds: 1),
        );
        expect(response.statusCode, 206);
        expect(
          response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 123-4095/131072',
        );
        expect(
          await response
              .fold<List<int>>([], (out, chunk) => out..addAll(chunk))
              .timeout(const Duration(seconds: 1)),
          payload.sublist(123, 4096),
        );
        expect(finish.isCompleted, isFalse);
        expect(relay.cachedBytes, 0);
        final invalid = await client.getUrl(uri);
        invalid.headers.set(HttpHeaders.rangeHeader, 'bytes=131072-');
        final rejected = await invalid.close().timeout(
          const Duration(seconds: 1),
        );
        expect(rejected.statusCode, 416);
        expect(
          rejected.headers.value(HttpHeaders.contentRangeHeader),
          'bytes */131072',
        );
        await rejected.drain<void>();
        finish.complete();
        final full = await (await client.getUrl(uri)).close();
        expect(
          await full.fold<List<int>>([], (out, chunk) => out..addAll(chunk)),
          payload,
        );
        final tail = await client.getUrl(uri);
        tail.headers.set(HttpHeaders.rangeHeader, 'bytes=-777');
        final suffix = await tail.close();
        expect(
          await suffix.fold<List<int>>([], (out, chunk) => out..addAll(chunk)),
          payload.sublist(payload.length - 777),
        );
        expect(fetches, 1);
      } finally {
        if (!finish.isCompleted) finish.complete();
        await relay.close();
        client.close(force: true);
        await origin.close(force: true);
      }
    },
  );
  test(
    'an interrupted progressive segment is never reused as a complete cache entry',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final payload = List.generate(128 * 1024, (i) => i & 255);
      var fetches = 0;
      origin.listen((request) async {
        if (request.uri.path.endsWith('.m3u8')) {
          request.response.write(
            '#EXTM3U\n#EXTINF:10,\n0.ts\n#EXT-X-ENDLIST\n',
          );
          await request.response.close();
        } else if (++fetches == 1) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.done.ignore();
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Length: ${payload.length}\r\nConnection: close\r\n\r\n',
          );
          socket.add(payload.sublist(0, 64 * 1024));
          await socket.flush();
          socket.destroy();
        } else {
          request.response.contentLength = payload.length;
          request.response.add(payload);
          await request.response.close();
        }
      });
      final relay = PublicHlsProxy(
        source: Uri.parse('http://127.0.0.1:${origin.port}/index.m3u8'),
        client: HttpClient(),
        allowUri: (uri) => uri.host == '127.0.0.1' && uri.port == origin.port,
      );
      final client = HttpClient();
      await relay.start();
      try {
        final manifest = await (await (await client.getUrl(
          relay.uri,
        )).close()).transform(utf8.decoder).join();
        final uri = Uri.parse(
          const LineSplitter()
              .convert(manifest)
              .firstWhere((line) => line.startsWith('http')),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(relay.cachedBytes, 0);
        final response = await (await client.getUrl(uri)).close();
        expect(
          await response.fold<List<int>>(
            [],
            (out, chunk) => out..addAll(chunk),
          ),
          payload,
        );
        expect(fetches, 2);
        expect(relay.cachedBytes, payload.length);
      } finally {
        await relay.close();
        client.close(force: true);
        await origin.close(force: true);
      }
    },
  );
  test(
    'a segment starts streaming before the origin finishes and keeps a valid complete cache',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final finish = Completer<void>();
      final payload = List.generate(128 * 1024, (i) => i & 255);
      var segmentFetches = 0;
      origin.listen((request) async {
        if (request.uri.path.endsWith('.m3u8')) {
          request.response.write(
            '#EXTM3U\n#EXTINF:10,\n0.ts\n#EXT-X-ENDLIST\n',
          );
        } else {
          segmentFetches++;
          request.response.contentLength = payload.length;
          request.response.add(payload.sublist(0, 64 * 1024));
          await request.response.flush();
          await finish.future;
          request.response.add(payload.sublist(64 * 1024));
        }
        try {
          await request.response.close();
        } catch (_) {}
      });
      final relay = PublicHlsProxy(
        source: Uri.parse('http://127.0.0.1:${origin.port}/index.m3u8'),
        client: HttpClient(),
        allowUri: (uri) => uri.host == '127.0.0.1' && uri.port == origin.port,
      );
      final client = HttpClient();
      await relay.start();
      try {
        final manifest = await (await (await client.getUrl(
          relay.uri,
        )).close()).transform(utf8.decoder).join();
        final uri = Uri.parse(
          const LineSplitter()
              .convert(manifest)
              .firstWhere((line) => line.startsWith('http')),
        );
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
        final response = await request.close().timeout(
          const Duration(seconds: 1),
          onTimeout: () =>
              throw TimeoutException('progressive response headers blocked'),
        );
        expect(response.statusCode, 206);
        expect(
          response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 0-131071/131072',
        );
        final first = Completer<void>();
        final bytes = <int>[];
        final done = Completer<void>();
        response.listen(
          (chunk) {
            bytes.addAll(chunk);
            if (!first.isCompleted) first.complete();
          },
          onDone: done.complete,
          onError: done.completeError,
        );
        await first.future.timeout(
          const Duration(seconds: 1),
          onTimeout: () =>
              throw TimeoutException('progressive first bytes blocked'),
        );
        expect(bytes, isNotEmpty);
        expect(bytes.length, lessThanOrEqualTo(64 * 1024));
        expect(finish.isCompleted, isFalse);
        finish.complete();
        await done.future;
        expect(bytes, payload);
        final cached = await (await client.getUrl(uri)).close();
        expect(
          await cached.fold<List<int>>([], (out, chunk) => out..addAll(chunk)),
          bytes,
        );
        expect(segmentFetches, 1);
      } finally {
        if (!finish.isCompleted) finish.complete();
        await relay.close();
        client.close(force: true);
        await origin.close(force: true);
      }
    },
  );
  test(
    'VOD manifest is shared and warms the resume window before segment requests',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      final gate = Completer<void>();
      origin.listen((request) async {
        paths.add(request.uri.path);
        if (request.uri.path == '/index.m3u8') {
          request.response.write(
            '#EXTM3U\n${List.generate(6, (i) => '#EXTINF:1,\n$i.ts').join('\n')}\n#EXT-X-ENDLIST\n',
          );
        } else {
          await gate.future;
          request.response.add([0, 1, 2]);
        }
        try {
          await request.response.close();
        } catch (_) {}
      });
      final relay = PublicHlsProxy(
        source: Uri.parse('http://127.0.0.1:${origin.port}/index.m3u8'),
        client: HttpClient(),
        allowUri: (uri) => uri.host == '127.0.0.1' && uri.port == origin.port,
        startPosition: const Duration(milliseconds: 3500),
        lookahead: 2,
      );
      final client = HttpClient();
      await relay.start();
      Future<String> manifest() async => (await (await client.getUrl(
        relay.uri,
      )).close()).transform(utf8.decoder).join();
      try {
        final manifests = await Future.wait([
          manifest(),
          manifest(),
        ]).timeout(const Duration(seconds: 1));
        expect(manifests[0], manifests[1]);
        expect(await manifest(), manifests[0]);
        for (var i = 0; i < 20 && paths.length < 3; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(paths.where((path) => path.endsWith('.m3u8')), hasLength(1));
        expect(paths, containsAll(['/3.ts', '/4.ts']));
        expect(paths, isNot(contains('/0.ts')));
      } finally {
        gate.complete();
        await relay.close();
        client.close(force: true);
        await origin.close(force: true);
      }
    },
  );
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
        lookahead: 4,
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
