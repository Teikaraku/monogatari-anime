import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:b_encode_decode/b_encode_decode.dart' as bencode;
import 'package:dtorrent_task_v2/src/standalone/dtorrent_tracker/tracker/http_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final options = <String, dynamic>{
    'downloaded': 0,
    'uploaded': 0,
    'left': 100,
    'port': 4567,
    'peerId': '-MO2400-123456789012',
  };

  test(
    'HTTP tracker keeps existing passkeys and parses real peer reply',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requested = Completer<Uri>();
      final listener = server.listen((request) async {
        requested.complete(request.uri);
        request.response.add(
          bencode.encode({
            'interval': 60,
            'peers': Uint8List.fromList([127, 0, 0, 1, 0x1a, 0xe1]),
          }),
        );
        await request.response.close();
      });
      final tracker = _QuickTracker(
        Uri.parse(
          'http://127.0.0.1:${server.port}/announce?passkey=fixture%2Fvalue',
        ),
      );
      try {
        final response = await tracker.announce('started', options);
        expect(response?.peers, hasLength(1));
        expect(
          (await requested.future).queryParameters['passkey'],
          'fixture/value',
        );
        expect((await requested.future).queryParameters['event'], 'started');
      } finally {
        await tracker.close();
        await listener.cancel();
        await server.close(force: true);
      }
    },
  );

  for (final sendsHeaders in [false, true]) {
    test(
      'HTTP tracker times out stalled ${sendsHeaders ? 'body' : 'headers'}',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final listener = server.listen((request) async {
          if (sendsHeaders) {
            request.response.write('d');
            await request.response.flush();
          }
        });
        final tracker = _QuickTracker(
          Uri.parse('http://127.0.0.1:${server.port}/announce'),
        );
        try {
          await expectLater(
            tracker.announce('started', options),
            throwsA(isA<TimeoutException>()),
          );
        } finally {
          await tracker.close();
          await listener.cancel();
          await server.close(force: true);
        }
      },
    );
  }

  test(
    'HTTP tracker rejects non-success status before bencode parsing',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final listener = server.listen((request) async {
        request.response.statusCode = 503;
        await request.response.close();
      });
      final tracker = _QuickTracker(
        Uri.parse('http://127.0.0.1:${server.port}/announce'),
      );
      try {
        await expectLater(
          tracker.announce('started', options),
          throwsA(isA<HttpException>()),
        );
      } finally {
        await tracker.close();
        await listener.cancel();
        await server.close(force: true);
      }
    },
  );
}

class _QuickTracker extends HttpTracker {
  _QuickTracker(Uri uri) : super(uri, Uint8List.fromList(List.filled(20, 7)));

  @override
  Duration get requestTimeout => const Duration(milliseconds: 250);
}
