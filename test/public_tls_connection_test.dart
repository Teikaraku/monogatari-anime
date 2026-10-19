import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/api_video/public_video_proxy.dart';
import 'package:kazumi/services/network/public_dns_resolver.dart';

SecurityContext _serverContext() => SecurityContext()
  ..useCertificateChain('test/support/tls/server.pem')
  ..usePrivateKey('test/support/tls/server.key');
SecurityContext _trustedContext() =>
    SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('test/support/tls/server.pem');

void main() {
  test(
    'fast TCP edge with a failed TLS handshake cannot hide another verified edge',
    () async {
      final broken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      broken.listen((socket) => socket.destroy());
      final origin = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        _serverContext(),
      );
      origin.listen((request) async {
        request.response.write('healthy edge');
        await request.response.close();
      }, onError: (Object _) {});
      final first = InternetAddress('93.184.216.34');
      final second = InternetAddress('93.184.216.35');
      final opened = <InternetAddress>[];
      final guard = PublicVideoProxy(
        tlsContext: _trustedContext(),
        lookup: (_) async => [first, second],
        connect: (address, _) {
          opened.add(address);
          return Socket.connect(
            InternetAddress.loopbackIPv4,
            address == first ? broken.port : origin.port,
          );
        },
      );
      await guard.start();
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      client.connectionFactory = (uri, _, _) => guard.secureConnectionTask(uri);
      try {
        final response = await (await client.getUrl(
          Uri.parse('https://cdn.test/video.ts'),
        )).close().timeout(const Duration(seconds: 2));
        expect(
          await response.transform(const SystemEncoding().decoder).join(),
          'healthy edge',
        );
        expect(opened, containsAll([first, second]));
        await expectLater(
          client.getUrl(Uri.parse('https://other.test/video.ts')),
          throwsA(isA<HandshakeException>()),
        );
      } finally {
        client.close(force: true);
        await guard.close();
        await broken.close();
        await origin.close(force: true);
      }
    },
  );
  test(
    'custom direct HTTPS connections perform TLS and keep hostname validation',
    () async {
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        _serverContext(),
      );
      server.listen((request) async {
        request.response.write('verified TLS');
        await request.response.close();
      }, onError: (Object _) {});
      final client = HttpClient(context: _trustedContext())
        ..findProxy = (_) => 'DIRECT';
      client.connectionFactory = (uri, _, _) => verifiedTlsConnectionTask(
        Socket.startConnect(InternetAddress.loopbackIPv4, server.port),
        uri.host,
        context: _trustedContext(),
      );
      try {
        final response = await (await client.getUrl(
          Uri.parse('https://cdn.test:${server.port}/'),
        )).close();
        expect(response.statusCode, 200);
        await response.drain<void>();
        await expectLater(
          client.getUrl(Uri.parse('https://other.test:${server.port}/')),
          throwsA(isA<HandshakeException>()),
        );
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    },
  );

  test(
    'guarded HTTPS pool reuses one validated tunnel for more than sixteen segments',
    () async {
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        _serverContext(),
      );
      final ports = <int>{};
      server.listen((request) async {
        ports.add(request.connectionInfo!.remotePort);
        request.response.write('segment');
        await request.response.close();
      }, onError: (Object _) {});
      var tunnels = 0;
      final guard = PublicVideoProxy(
        tlsContext: _trustedContext(),
        lookup: (_) async => [InternetAddress('93.184.216.34')],
        connect: (_, _) {
          tunnels++;
          return Socket.connect(InternetAddress.loopbackIPv4, server.port);
        },
      );
      await guard.start();
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      client.connectionFactory = (uri, _, _) => guard.secureConnectionTask(uri);
      try {
        for (var i = 0; i < 24; i++) {
          final response = await (await client.getUrl(
            Uri.parse('https://cdn.test/$i.ts'),
          )).close();
          expect(response.statusCode, 200);
          await response.drain<void>();
        }
        expect(tunnels, 1);
        expect(ports, hasLength(1));
      } finally {
        client.close(force: true);
        await guard.close();
        await server.close(force: true);
      }
    },
  );

  test('cancelling a pending TLS handshake releases its socket', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peers = <Socket>[];
    final closed = Completer<void>();
    server.listen((socket) {
      peers.add(socket);
      socket.listen(
        (_) {},
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
      );
    });
    final task = await verifiedTlsConnectionTask(
      Socket.startConnect(InternetAddress.loopbackIPv4, server.port),
      'cdn.test',
    );
    task.socket.ignore();
    try {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      task.cancel();
      await closed.future.timeout(const Duration(seconds: 2));
    } finally {
      for (final peer in peers) {
        peer.destroy();
      }
      await server.close();
    }
  });
}
