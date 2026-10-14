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
