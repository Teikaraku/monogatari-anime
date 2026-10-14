import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/api_video/public_video_proxy.dart';

void main() {
  test(
    'upstream EOF closes the client and releases slots across many short segments',
    () async {
      final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final peers = <Socket>[];
      origin.listen((socket) {
        peers.add(socket);
        socket.listen((data) async {
          socket.add(data);
          await socket.flush();
          await socket.close();
        });
      });
      final proxy = PublicVideoProxy(
        lookup: (_) async => [InternetAddress('93.184.216.34')],
        connect: (_, _) =>
            Socket.connect(InternetAddress.loopbackIPv4, origin.port),
      );
      await proxy.start();
      try {
        for (var i = 0; i < 24; i++) {
          final socket = await Socket.connect(
            InternetAddress.loopbackIPv4,
            proxy.port,
          );
          var received = '';
          var sent = false;
          final done = Completer<void>();
          final subscription = socket.listen((bytes) {
            received += latin1.decode(bytes);
            if (received.contains('\r\n\r\n') && !sent) {
              sent = true;
              socket.write('PING');
            }
          }, onDone: done.complete);
          try {
            socket.write(
              'CONNECT cdn.test:443 HTTP/1.1\r\nProxy-Authorization: ${proxy.authorization}\r\n\r\n',
            );
            await done.future.timeout(const Duration(seconds: 2));
            expect(received, contains('200 Connection Established'));
            expect(received, endsWith('PING'));
          } finally {
            socket.destroy();
            await subscription.cancel();
          }
        }
      } finally {
        await proxy.close();
        for (final peer in peers) {
          peer.destroy();
        }
        await origin.close();
      }
    },
  );
  test(
    'unauthenticated and non-HTTPS destinations never open a socket',
    () async {
      var opened = 0;
      final proxy = PublicVideoProxy(
        connect: (_, _) async {
          opened++;
          throw StateError('unexpected');
        },
      );
      await proxy.start();
      try {
        expect(
          await _request(proxy, 'cdn.test:443', authenticated: false),
          contains('407'),
        );
        for (final target in [
          '127.0.0.1:443',
          '10.0.0.1:443',
          'localhost:443',
          'cdn.test:80',
        ]) {
          expect(await _request(proxy, target), contains('403'));
        }
        expect(opened, 0);
      } finally {
        await proxy.close();
      }
    },
  );

  test(
    'a hostname resolving to a private address is rejected before connect',
    () async {
      var opened = false;
      final proxy = PublicVideoProxy(
        lookup: (_) async => [InternetAddress('192.168.0.10')],
        connect: (_, _) async {
          opened = true;
          throw StateError('unexpected');
        },
      );
      await proxy.start();
      try {
        expect(await _request(proxy, 'cdn.test:443'), contains('403'));
        expect(opened, isFalse);
      } finally {
        await proxy.close();
      }
    },
  );

  test(
    'validated addresses are pinned and the tunnel streams without retaining payload',
    () async {
      final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final listener = origin.listen((socket) {
        sockets.add(socket);
        socket.listen((bytes) => socket.add(bytes));
      });
      final opened = <(String, int)>[];
      final proxy = PublicVideoProxy(
        lookup: (_) async => [InternetAddress('93.184.216.34')],
        connect: (ip, port) async {
          opened.add((ip.address, port));
          return Socket.connect(InternetAddress.loopbackIPv4, origin.port);
        },
      );
      await proxy.start();
      try {
        final response = await _request(proxy, 'cdn.test:443', echo: true);
        expect(response, contains('200 Connection Established'));
        expect(response, contains('PING'));
        expect(opened, [('93.184.216.34', 443)]);
      } finally {
        await proxy.close();
        for (final socket in sockets) {
          socket.destroy();
        }
        await listener.cancel();
        await origin.close();
      }
    },
  );

  test(
    'configured upstream proxy receives the pinned IP and preserves duplex data',
    () async {
      final upstream = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final headers = <String>[];
      final listener = upstream.listen((socket) {
        sockets.add(socket);
        var header = '';
        var ready = false;
        socket.listen((bytes) {
          if (ready) {
            socket.add(bytes);
            return;
          }
          header += latin1.decode(bytes);
          if (!header.contains('\r\n\r\n')) return;
          headers.add(header);
          ready = true;
          socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        });
      });
      final proxy = PublicVideoProxy(
        lookup: (_) async => [InternetAddress('93.184.216.34')],
        proxyForUri: (_) => Uri.parse('http://127.0.0.1:${upstream.port}'),
      );
      await proxy.start();
      try {
        expect(
          await _request(proxy, 'cdn.test:443', echo: true),
          contains('PING'),
        );
        expect(
          headers.single,
          startsWith('CONNECT 93.184.216.34:443 HTTP/1.1'),
        );
      } finally {
        await proxy.close();
        for (final socket in sockets) {
          socket.destroy();
        }
        await listener.cancel();
        await upstream.close();
      }
    },
  );
}

Future<String> _request(
  PublicVideoProxy proxy,
  String target, {
  bool authenticated = true,
  bool echo = false,
}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, proxy.port);
  final ready = Completer<String>();
  var received = '';
  var sent = false;
  final subscription = socket.listen(
    (bytes) {
      received += latin1.decode(bytes);
      if (!received.contains('\r\n\r\n')) return;
      if (echo && received.startsWith('HTTP/1.1 200')) {
        if (!sent) {
          sent = true;
          socket.write('PING');
        }
        if (!received.contains('PING')) return;
      }
      if (!ready.isCompleted) ready.complete(received);
    },
    onError: (Object error) {
      if (!ready.isCompleted) ready.completeError(error);
    },
  );
  try {
    socket.write(
      'CONNECT $target HTTP/1.1\r\nHost: $target\r\n${authenticated ? 'Proxy-Authorization: ${proxy.authorization}\r\n' : ''}\r\n',
    );
    return await ready.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        throw TimeoutException(
          'target=$target authenticated=$authenticated response=$received',
        );
      },
    );
  } finally {
    socket.destroy();
    await subscription.cancel();
  }
}
