import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/torrent/dart_torrent_engine.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'support/torrent_loopback_fixture.dart';

void main() {
  test(
    'concurrent torrent readers keep exact ranges through piece reuse, seek and cancellation',
    () async {
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final payload = Uint8List(40 * 524288);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = (i ~/ 16384 + i * 31) & 255;
      }
      final fixture = TorrentLoopbackFixture(data: payload, pieceLength: 524288)
        ..withheld.add(0);
      final directory = await Directory.systemTemp.createTemp(
        'monogatari-range-reuse-',
      );
      final engine = DartTorrentEngine(allowLoopbackPeers: true);
      final token = CancelToken();
      final cancelled = CancelToken();
      dynamic handle;
      await fixture.start();
      try {
        final metadata = await engine.resolve(
          fixture.source,
          cancelToken: token,
        );
        handle = await engine.open(metadata, directory, cancelToken: token);
        await handle.resume();
        final discarded =
            handle.read('cancelled', 0, 0, 4096, cancelToken: cancelled)
                as Future<Uint8List>;
        final cancellation = expectLater(
          discarded,
          throwsA(isA<DioException>()),
        );
        final first =
            handle.read('head', 0, 123, 32768, cancelToken: token)
                as Future<Uint8List>;
        final second =
            handle.read('probe', 0, 70000, 65536, cancelToken: token)
                as Future<Uint8List>;
        cancelled.cancel('Seek abandoned');
        await cancellation;
        fixture.release(0);
        expect(
          await first.timeout(const Duration(seconds: 5)),
          payload.sublist(123, 32891),
        );
        expect(await second, payload.sublist(70000, 135536));
        for (final offset in [
          for (var i = 1; i <= 11; i++) i * 524288 + 777,
          524000,
          0,
          70000,
        ]) {
          final size = 524288 - offset % 524288;
          final length = size < 4096 ? size : 4096;
          expect(
            await handle.read('head', 0, offset, length, cancelToken: token),
            payload.sublist(offset, offset + length),
          );
        }
        expect((await handle.snapshot()).peers, greaterThan(0));
      } finally {
        token.cancel('Test complete');
        await handle?.close();
        await engine.dispose();
        await fixture.close();
        await directory.delete(recursive: true);
        HttpOverrides.global = overrides;
      }
    },
  );
  test(
    'a disconnected seeder releases reserved blocks without stopping the shared BT worker',
    () async {
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final payload = Uint8List.fromList(
        List.generate(8 * 65536, (i) => i & 255),
      );
      final slow = TorrentLoopbackFixture(data: payload, pieceLength: 65536)
        ..withheld.add(0);
      final fast = TorrentLoopbackFixture(data: payload, pieceLength: 65536)
        ..handshakeDelay = const Duration(milliseconds: 600)
        ..peerId = '-MO0001-012345678902';
      final directory = await Directory.systemTemp.createTemp(
        'monogatari-seeder-reset-',
      );
      final engine = DartTorrentEngine(allowLoopbackPeers: true);
      final token = CancelToken();
      await slow.start();
      await fast.start();
      slow.extraPeers = [(InternetAddress.loopbackIPv4, fast.seeder.port)];
      dynamic handle;
      try {
        final metadata = await engine.resolve(slow.source, cancelToken: token);
        handle = await engine.open(metadata, directory, cancelToken: token);
        await handle.resume();
        final read = handle.read('stream', 0, 0, 4096, cancelToken: token);
        for (var i = 0; i < 50 && !slow.requests.contains(0); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(slow.requests, contains(0));
        slow.disconnectPeers();
        expect(
          await read.timeout(const Duration(seconds: 4)),
          payload.sublist(0, 4096),
        );
        expect(fast.requests, contains(0));
        expect((await handle.snapshot()).files, isNotEmpty);
      } finally {
        token.cancel('Test complete');
        await handle?.close();
        await engine.dispose();
        await slow.close();
        await fast.close();
        await directory.delete(recursive: true);
        HttpOverrides.global = overrides;
      }
    },
  );
  test(
    'streaming hedges urgent blocks to a working peer without waiting for timeout',
    () async {
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      // Stay larger than the 16 MiB prefetch window without allocating a
      // second 20 MiB boxed integer list during the concurrent test suite.
      final payload = Uint8List(40 * 524288);
      final slow = TorrentLoopbackFixture(data: payload, pieceLength: 524288)
        ..withheld.add(0);
      final fast = TorrentLoopbackFixture(data: payload, pieceLength: 524288)
        ..handshakeDelay = const Duration(milliseconds: 300)
        ..peerId = '-MO0001-012345678902';
      final directory = await Directory.systemTemp.createTemp(
        'monogatari-stream-handoff-',
      );
      final engine = DartTorrentEngine(allowLoopbackPeers: true);
      final token = CancelToken();
      await slow.start();
      await fast.start();
      slow.extraPeers = [(InternetAddress.loopbackIPv4, fast.seeder.port)];
      dynamic handle;
      try {
        final metadata = await engine.resolve(slow.source, cancelToken: token);
        handle = await engine.open(metadata, directory, cancelToken: token);
        await handle.resume();
        final bytes = await handle
            .read('stream', 0, 0, 4096, cancelToken: token)
            .timeout(const Duration(seconds: 4));
        expect(bytes, payload.sublist(0, 4096));
        expect(slow.requests, contains(0));
        expect(fast.requests, contains(0));
        // A cancelled response can already be in transit; it must not cause
        // a legitimate peer to be dropped as if it sent unsolicited data.
        slow.release(0);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect((await handle.snapshot()).peers, 2);
      } finally {
        token.cancel('Test finished');
        await handle?.close();
        await engine.dispose();
        await slow.close();
        await fast.close();
        await directory.delete(recursive: true);
        HttpOverrides.global = overrides;
      }
    },
  );

  test(
    'real BT engine streams verified bytes over the production loopback URL and releases temporary storage',
    () async {
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final payload = Uint8List.fromList(
        List.generate(16 * 16384, (i) => (i * 31) & 255),
      );
      final fixture = TorrentLoopbackFixture(data: payload);
      final directory = await Directory.systemTemp.createTemp(
        'monogatari-http-integration-',
      );
      final service = TorrentService(
        engine: DartTorrentEngine(allowLoopbackPeers: true),
        directoryProvider: () async => directory,
      );
      final client = HttpClient();
      await fixture.start();
      try {
        final task = await service.add(fixture.source);
        final lease = await service.openStream(task.id, 0);
        final head = await (await client.headUrl(lease.url)).close();
        expect(head.statusCode, 200);
        expect(head.contentLength, payload.length);
        await head.drain<void>();
        for (final offset in [0, payload.length - 4096]) {
          final request = await client.getUrl(lease.url);
          request.headers.set(
            HttpHeaders.rangeHeader,
            'bytes=$offset-${offset + 4095}',
          );
          final response = await request.close().timeout(
            const Duration(seconds: 5),
          );
          expect(response.statusCode, 206);
          final bytes = await response.fold<List<int>>(
            [],
            (out, chunk) => out..addAll(chunk),
          );
          expect(bytes, payload.sublist(offset, offset + 4096));
        }
        expect(service.tasks, hasLength(1));
        await lease.close();
        expect(service.tasks, isEmpty);
      } finally {
        client.close(force: true);
        await service.dispose();
        await fixture.close();
        expect(directory.path, startsWith(Directory.systemTemp.path));
        await directory.delete(recursive: true);
        HttpOverrides.global = overrides;
      }
    },
  );
}
