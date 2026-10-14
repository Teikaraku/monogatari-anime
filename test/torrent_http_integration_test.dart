import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/torrent/dart_torrent_engine.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'support/torrent_loopback_fixture.dart';

void main() {
  test('real BT engine streams verified bytes over the production loopback URL and releases temporary storage', () async {
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final payload = Uint8List.fromList(List.generate(16 * 16384, (i) => (i * 31) & 255));
    final fixture = TorrentLoopbackFixture(data: payload);
    final directory = await Directory.systemTemp.createTemp('monogatari-http-integration-');
    final service = TorrentService(engine: DartTorrentEngine(allowLoopbackPeers: true),
      directoryProvider: () async => directory);
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
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-${offset + 4095}');
        final response = await request.close().timeout(const Duration(seconds: 5));
        expect(response.statusCode, 206);
        final bytes = await response.fold<List<int>>([], (out, chunk) => out..addAll(chunk));
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
  });
}
