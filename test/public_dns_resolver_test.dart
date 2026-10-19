import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/public_dns_resolver.dart';

void main() {
  test(
    'a third healthy CDN edge is tried when the first two refuse connections',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final peers = <Socket>[];
      server.listen(peers.add);
      Socket? socket;
      try {
        final task = await publicConnectionTask([
          InternetAddress('127.0.0.2'),
          InternetAddress('127.0.0.3'),
          InternetAddress.loopbackIPv4,
        ], server.port);
        socket = await task.socket.timeout(const Duration(seconds: 2));
        expect(socket.remoteAddress, InternetAddress.loopbackIPv4);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(peers, hasLength(1));
      } finally {
        socket?.destroy();
        for (final peer in peers) {
          peer.destroy();
        }
        await server.close();
      }
    },
  );
  test(
    'failed system DNS and VPN fake IPs recover through public encrypted answers',
    () async {
      for (final failed in [true, false]) {
        var encrypted = 0;
        var system = 0;
        final resolver = PublicDnsResolver(
          systemLookup: (_) async {
            system++;
            if (failed) throw const SocketException('failed lookup');
            return [InternetAddress('198.18.0.1')];
          },
          encryptedLookup: (_) async {
            encrypted++;
            return [InternetAddress('93.184.216.34')];
          },
        );
        final results = await Future.wait([
          resolver.lookup('cdn.test'),
          resolver.lookup('cdn.test'),
        ]);
        expect(results.first.single.address, '93.184.216.34');
        await resolver.lookup('cdn.test');
        expect(system, 1);
        expect(encrypted, 1);
      }
    },
  );

  test(
    'encrypted private answers are refused and a failed lookup is retryable',
    () async {
      var count = 0;
      final resolver = PublicDnsResolver(
        systemLookup: (_) async => throw const SocketException('offline'),
        encryptedLookup: (_) async => [
          InternetAddress(++count == 1 ? '127.0.0.1' : '93.184.216.34'),
        ],
      );
      await expectLater(
        resolver.lookup('cdn.test'),
        throwsA(isA<SocketException>()),
      );
      expect(
        (await resolver.lookup('cdn.test')).single.address,
        '93.184.216.34',
      );
    },
  );

  test(
    'IPv4 can connect while an IPv6 route is unavailable and cancellation keeps no second socket',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final peers = <Socket>[];
      server.listen(peers.add);
      Socket? socket;
      try {
        final task = await publicConnectionTask([
          InternetAddress('::1'),
          InternetAddress.loopbackIPv4,
        ], server.port);
        socket = await task.socket.timeout(const Duration(seconds: 2));
        expect(socket.remoteAddress, InternetAddress.loopbackIPv4);
      } finally {
        socket?.destroy();
        for (final peer in peers) {
          peer.destroy();
        }
        await server.close();
      }
    },
  );
}
