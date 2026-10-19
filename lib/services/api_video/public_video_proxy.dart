import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'api_video_url_policy.dart';
import 'package:kazumi/services/network/public_dns_resolver.dart';

/// Scoped HTTPS CONNECT route shared by native playback and API downloads.
/// Each connection pins its validated DNS result, including redirects, HLS
/// segments and keys. Payload flows between sockets without file storage.
class PublicVideoProxy {
  PublicVideoProxy({
    this.proxyForUri,
    Future<List<InternetAddress>> Function(String)? lookup,
    bool Function(InternetAddress)? allowAddress,
    Future<Socket> Function(InternetAddress, int)? connect,
    SecurityContext? tlsContext,
  }) : _lookup = lookup ?? PublicDnsResolver(proxyForUri: proxyForUri).lookup,
       _allowAddress = allowAddress ?? isPublicVideoAddress,
       _connect = connect,
       _tlsContext = tlsContext;

  final Uri? Function(Uri)? proxyForUri;
  final Future<List<InternetAddress>> Function(String) _lookup;
  final bool Function(InternetAddress) _allowAddress;
  final Future<Socket> Function(InternetAddress, int)? _connect;
  final SecurityContext? _tlsContext;
  final username = base64Url.encode(
    List.generate(24, (_) => Random.secure().nextInt(256)),
  );
  ServerSocket? _server;
  final _sockets = <Socket>{};
  final _clients = <Socket>{};
  final _acceptedByPort = <int, Socket>{};
  final _preferredByPort = <int, InternetAddress>{};
  bool _closed = false;
  String get realm => 'Monogatari media';
  int get port => _server!.port;
  Uri get uri => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: port,
    userInfo: '$username:',
  );
  String get authorization =>
      'Basic ${base64.encode(utf8.encode('$username:'))}';

  /// Keep HttpClient's pool keyed by the origin instead of the local proxy.
  /// Dart's built-in HTTPS proxy path stores idle tunnels under the origin but
  /// looks them up under the proxy, repeatedly opening new idle connections.
  Future<ConnectionTask<Socket>> secureConnectionTask(Uri target) async {
    if (_closed || !isPublicVideoUri(target))
      throw const FormatException('片源地址不符合安全要求');
    final addresses = await _lookup(
      target.host,
    ).timeout(const Duration(seconds: 5));
    if (addresses.isEmpty || addresses.any((ip) => !_allowAddress(ip))) {
      throw const FormatException('片源指向非公开网络');
    }
    final candidates = addresses.toSet().take(4).toList();
    final ready = Completer<Socket>();
    final tasks = <ConnectionTask<Socket>>[];
    var next = 0, active = 0;
    var cancelled = false;
    Timer? hedge;
    void cancel() {
      cancelled = true;
      hedge?.cancel();
      for (final task in tasks) {
        task.cancel();
      }
    }

    void launch() {
      if (cancelled || ready.isCompleted || next >= candidates.length) return;
      final address = candidates[next++];
      active++;
      unawaited(() async {
        ConnectionTask<Socket>? task;
        try {
          task = await _secureToAddress(target, address);
          tasks.add(task);
          if (cancelled || ready.isCompleted) {
            task.cancel();
            return;
          }
          final socket = await task.socket.timeout(
            const Duration(seconds: 8),
            onTimeout: () {
              task!.cancel();
              throw TimeoutException('Video TLS handshake timed out');
            },
          );
          if (cancelled || ready.isCompleted) {
            socket.destroy();
            return;
          }
          ready.complete(socket);
          hedge?.cancel();
          for (final other in tasks) {
            if (!identical(other, task)) other.cancel();
          }
        } catch (error, stack) {
          task?.cancel();
          if (!cancelled &&
              !ready.isCompleted &&
              next >= candidates.length &&
              active == 1) {
            ready.completeError(error, stack);
          }
        } finally {
          active--;
          if (!cancelled && !ready.isCompleted) launch();
        }
      }());
    }

    launch();
    hedge = Timer(const Duration(milliseconds: 250), () {
      if (active < 2) launch();
    });
    return ConnectionTask.fromSocket(ready.future, cancel);
  }

  Future<ConnectionTask<Socket>> _secureToAddress(
    Uri target,
    InternetAddress address,
  ) async {
    final task = await Socket.startConnect(InternetAddress.loopbackIPv4, port);
    Socket? connection;
    int? sourcePort;
    var cancelled = false;
    void cancel() {
      cancelled = true;
      task.cancel();
      connection?.destroy();
      // The raw client socket is detached during a TLS handshake. Its paired
      // server socket remains cancelable until the secure socket is ready.
      _acceptedByPort[sourcePort]?.destroy();
    }

    final ready = task.socket.then<Socket>((socket) async {
      connection = socket;
      sourcePort = socket.port;
      _preferredByPort[sourcePort!] = address;
      _Headers? input;
      try {
        if (cancelled || _closed)
          throw const SocketException('Media connection cancelled');
        socket.setOption(SocketOption.tcpNoDelay, true);
        socket.write(
          'CONNECT ${target.host}:${target.port} HTTP/1.1\r\nProxy-Authorization: $authorization\r\n\r\n',
        );
        await socket.flush();
        input = await _readHeaders(socket);
        if (!input.text.startsWith('HTTP/1.1 200 '))
          throw const HttpException('Media connection refused');
        final tls = await SecureSocket.secure(
          socket,
          host: target.host,
          context: _tlsContext,
        );
        connection = tls;
        if (cancelled || _closed) {
          tls.destroy();
          throw const SocketException('Media connection cancelled');
        }
        return tls;
      } catch (_) {
        connection?.destroy();
        rethrow;
      } finally {
        _preferredByPort.remove(sourcePort);
        await input?.cancel();
      }
    });
    return ConnectionTask.fromSocket(ready, cancel);
  }

  Future<void> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close();
      throw StateError('Media route closed');
    }
    _server = server;
    server.listen((socket) => unawaited(_serve(socket)));
  }

  Future<void> _serve(Socket client) async {
    Socket? upstream;
    _Headers? input;
    var established = false;
    if (_closed || _clients.length >= 24) {
      await _reject(client, 503);
      return;
    }
    _clients.add(client);
    final sourcePort = client.remotePort;
    _acceptedByPort[sourcePort] = client;
    _sockets.add(client);
    client.setOption(SocketOption.tcpNoDelay, true);
    try {
      input = await _readHeaders(client);
      final lines = input.text.split('\r\n');
      final auth = lines
          .skip(1)
          .where(
            (line) => line.toLowerCase().startsWith('proxy-authorization:'),
          )
          .toList();
      if (auth.length != 1 ||
          auth.single.substring(auth.single.indexOf(':') + 1).trim() !=
              authorization) {
        await _reject(client, 407, challenge: true);
        return;
      }
      final first = lines.first.split(' ');
      final target = first.length == 3
          ? Uri.tryParse('https://${first[1]}')
          : null;
      if (first.length != 3 ||
          first.first != 'CONNECT' ||
          target == null ||
          !isPublicVideoUri(target) ||
          target.path.isNotEmpty ||
          target.hasQuery) {
        await _reject(client, 403);
        return;
      }
      final addresses = await _lookup(
        target.host,
      ).timeout(const Duration(seconds: 5));
      if (addresses.isEmpty || addresses.any((ip) => !_allowAddress(ip))) {
        throw const FormatException('片源指向非公开网络');
      }
      final preferred = _preferredByPort[sourcePort];
      if (preferred != null && !addresses.contains(preferred)) {
        throw const FormatException('片源连接地址已失效');
      }
      final tunnel = await _open(
        target,
        preferred == null ? addresses : [preferred],
        proxyForUri?.call(target),
      );
      upstream = tunnel.$1;
      upstream.setOption(SocketOption.tcpNoDelay, true);
      _sockets.add(upstream);
      if (_closed) throw StateError('Media route closed');
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      await client.flush();
      established = true;
      await Future.any([
        client.addStream(tunnel.$2),
        upstream.addStream(input.body),
      ]);
      await client.flush().timeout(const Duration(seconds: 1));
    } catch (_) {
      if (!established) {
        try {
          await _reject(client, 403);
        } catch (_) {}
      }
    } finally {
      _clients.remove(client);
      _acceptedByPort.remove(sourcePort);
      _sockets.remove(client);
      client.destroy();
      if (upstream != null) {
        _sockets.remove(upstream);
        upstream.destroy();
      }
      // Upstream EOF can arrive while the player keeps its write side open.
      // Close both sockets before awaiting cancellation, or a completed
      // segment retains a tunnel slot and later segments eventually stall.
      await input?.cancel();
    }
  }

  Future<(Socket, Stream<List<int>>)> _open(
    Uri target,
    List<InternetAddress> addresses,
    Uri? proxy,
  ) async {
    Object? lastError;
    if (proxy == null && _connect == null) {
      final task = await publicConnectionTask(addresses, target.port);
      try {
        final socket = await task.socket.timeout(const Duration(seconds: 8));
        if (_closed) {
          socket.destroy();
          throw StateError('Media route closed');
        }
        return (socket, socket);
      } catch (_) {
        task.cancel();
        rethrow;
      }
    }
    for (final address in addresses) {
      Socket? socket;
      try {
        if (_closed) throw StateError('Media route closed');
        if (proxy == null) {
          socket = await _connect!(address, target.port);
          if (_closed) {
            socket.destroy();
            throw StateError('Media route closed');
          }
          return (socket, socket);
        }
        if (proxy.scheme != 'http')
          throw const FormatException('Unsupported upstream proxy');
        socket = await Socket.connect(
          proxy.host,
          proxy.port,
          timeout: const Duration(seconds: 8),
        );
        _sockets.add(socket);
        if (_closed) throw StateError('Media route closed');
        final endpoint = address.type == InternetAddressType.IPv6
            ? '[${address.address}]'
            : address.address;
        socket.write(
          'CONNECT $endpoint:${target.port} HTTP/1.1\r\nHost: ${target.host}:${target.port}\r\n\r\n',
        );
        await socket.flush();
        final response = await _readHeaders(socket);
        if (!RegExp(r'^HTTP/1\.[01] 200(?: |\r)').hasMatch(response.text)) {
          await response.cancel();
          throw const HttpException('Upstream proxy refused video connection');
        }
        return (socket, response.body);
      } catch (error) {
        lastError = error;
        if (socket != null) {
          _sockets.remove(socket);
          socket.destroy();
        }
      }
    }
    throw lastError ??
        const SocketException('No reachable public video address');
  }

  Future<_Headers> _readHeaders(Socket socket) async {
    final data = <int>[];
    final body = StreamController<List<int>>();
    final ready = Completer<String>();
    late StreamSubscription<List<int>> subscription;
    subscription = socket.listen(
      (bytes) {
        if (ready.isCompleted) {
          body.add(bytes);
          return;
        }
        data.addAll(bytes);
        final text = latin1.decode(data);
        final end = text.indexOf('\r\n\r\n');
        if (end > 8192 || (end < 0 && data.length > 8192)) {
          ready.completeError(const FormatException('Proxy headers too large'));
          return;
        }
        if (end < 0) return;
        subscription.pause();
        ready.complete(text.substring(0, end));
        final tail = data.sublist(end + 4);
        if (tail.isNotEmpty) body.add(tail);
      },
      onError: (Object error, StackTrace stack) {
        if (!ready.isCompleted) {
          ready.completeError(error, stack);
        } else {
          body.addError(error, stack);
        }
      },
      onDone: () {
        if (!ready.isCompleted)
          ready.completeError(
            const HttpException('Proxy closed before headers'),
          );
        unawaited(body.close());
      },
    );
    body.onListen = subscription.resume;
    body.onPause = subscription.pause;
    body.onResume = subscription.resume;
    body.onCancel = subscription.cancel;
    try {
      final text = await ready.future.timeout(const Duration(seconds: 8));
      return _Headers(text, body.stream, subscription.cancel);
    } catch (_) {
      await subscription.cancel();
      unawaited(body.close());
      rethrow;
    }
  }

  Future<void> _reject(
    Socket socket,
    int status, {
    bool challenge = false,
  }) async {
    try {
      socket.write(
        'HTTP/1.1 $status Rejected\r\nContent-Length: 0\r\nConnection: close\r\n'
        '${challenge ? 'Proxy-Authenticate: Basic realm="$realm"\r\n' : ''}\r\n',
      );
      await socket.flush();
    } finally {
      socket.destroy();
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
    await _server?.close();
  }
}

class _Headers {
  const _Headers(this.text, this.body, this.cancel);
  final String text;
  final Stream<List<int>> body;
  final Future<void> Function() cancel;
}
