import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kazumi/services/api_video/api_video_url_policy.dart';

typedef PublicDnsQuery = Future<List<InternetAddress>> Function(String host);

/// Recover failed system DNS (including VPN fake addresses) with verified DoH.
/// Successful TCP connections are pinned; TLS continues to verify the hostname.
class PublicDnsResolver {
  PublicDnsResolver({
    this.proxyForUri,
    PublicDnsQuery? systemLookup,
    PublicDnsQuery? encryptedLookup,
  }) : _systemLookup = systemLookup ?? InternetAddress.lookup,
       _encryptedLookup = encryptedLookup;

  final Uri? Function(Uri)? proxyForUri;
  final PublicDnsQuery _systemLookup;
  final PublicDnsQuery? _encryptedLookup;
  final _pending = <String, Future<List<InternetAddress>>>{};
  final _cache = <String, (DateTime, List<InternetAddress>)>{};

  Future<List<InternetAddress>> lookup(String host) {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return Future.value(_validate([literal]));
    final cached = _cache[host];
    if (cached != null && DateTime.now().isBefore(cached.$1)) {
      return Future.value(cached.$2);
    }
    return _pending.putIfAbsent(host, () async {
      try {
        List<InternetAddress> addresses;
        try {
          addresses = _validate(
            await _systemLookup(host).timeout(const Duration(seconds: 2)),
          );
        } catch (_) {
          addresses = await encrypted(host);
        }
        _cache.remove(host);
        _cache[host] = (
          DateTime.now().add(const Duration(seconds: 30)),
          addresses,
        );
        while (_cache.length > 64) {
          _cache.remove(_cache.keys.first);
        }
        return addresses;
      } finally {
        _pending.remove(host);
      }
    });
  }

  Future<List<InternetAddress>> encrypted(String host) async {
    final injected = _encryptedLookup;
    if (injected != null) return _validate(await injected(host));
    // The bootstrap sockets use fixed resolver IPs to avoid the failed DNS
    // path. HttpClient still verifies the resolver's HTTPS certificate.
    final queries = [
      _query(
        Uri.https('dns.alidns.com', '/resolve', {'name': host, 'type': 'A'}),
        '223.5.5.5',
      ),
      _query(
        Uri.https('cloudflare-dns.com', '/dns-query', {
          'name': host,
          'type': 'A',
        }),
        '1.1.1.1',
      ),
    ];
    final ready = Completer<List<InternetAddress>>();
    var remaining = queries.length;
    for (final query in queries) {
      unawaited(
        query
            .then((addresses) {
              if (!ready.isCompleted) ready.complete(_validate(addresses));
            })
            .catchError((Object error) {
              if (--remaining == 0 && !ready.isCompleted)
                ready.completeError(error);
            }),
      );
    }
    return ready.future;
  }

  Future<List<InternetAddress>> _query(Uri uri, String bootstrap) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    final proxy = proxyForUri?.call(uri);
    if (proxy != null)
      client.findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}';
    client.connectionFactory = (uri, proxyHost, proxyPort) => proxyHost != null
        ? Socket.startConnect(proxyHost, proxyPort!)
        : verifiedTlsConnectionTask(
            Socket.startConnect(InternetAddress(bootstrap), 443),
            uri.host,
          );
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 4));
      request.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      if (response.statusCode != 200)
        throw const SocketException('DNS service unavailable');
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 4))) {
        if (bytes.length + chunk.length > 16 * 1024)
          throw const FormatException('DNS response too large');
        bytes.addAll(chunk);
      }
      final data = jsonDecode(utf8.decode(bytes)) as Map;
      if (data['Status'] != 0) throw const SocketException('DNS lookup failed');
      return _validate(
        (data['Answer'] as List? ?? [])
            .whereType<Map>()
            .where((row) => row['type'] == 1 || row['type'] == 28)
            .map((row) => InternetAddress.tryParse(row['data'].toString()))
            .whereType<InternetAddress>()
            .toList(),
      );
    } finally {
      client.close(force: true);
    }
  }

  static List<InternetAddress> _validate(List<InternetAddress> addresses) {
    if (addresses.isEmpty || addresses.any((ip) => !isPublicVideoAddress(ip))) {
      throw const SocketException('DNS returned a non-public address');
    }
    return addresses;
  }
}

/// Race a bounded set of CDN edges, interleaving IPv4/IPv6 when available.
/// Cancellation also closes late sockets.
Future<ConnectionTask<Socket>> publicConnectionTask(
  List<InternetAddress> addresses,
  int port,
) async {
  final candidates = <InternetAddress>[addresses.first];
  final alternate = addresses.where((ip) => ip.type != addresses.first.type);
  if (alternate.isNotEmpty) {
    candidates.add(alternate.first);
  } else if (addresses.length > 1)
    candidates.add(addresses[1]);
  for (final address in addresses) {
    if (candidates.length >= 4) break;
    if (!candidates.contains(address)) candidates.add(address);
  }
  final ready = Completer<Socket>();
  final tasks = <ConnectionTask<Socket>>[];
  var cancelled = false;
  var remaining = candidates.length;
  void cancel() {
    cancelled = true;
    for (final task in tasks) {
      task.cancel();
    }
  }

  for (var i = 0; i < candidates.length; i++) {
    final ip = candidates[i];
    unawaited(
      Future<void>.delayed(Duration(milliseconds: i * 200), () async {
        try {
          if (cancelled) throw const SocketException('Connection cancelled');
          final task = await Socket.startConnect(ip, port);
          tasks.add(task);
          if (cancelled) task.cancel();
          final socket = await task.socket;
          if (cancelled || ready.isCompleted) {
            socket.destroy();
            return;
          }
          ready.complete(socket);
          cancelled = true;
          for (final other in tasks) {
            if (!identical(other, task)) other.cancel();
          }
        } catch (error) {
          if (--remaining == 0 && !ready.isCompleted)
            ready.completeError(error);
        }
      }),
    );
  }
  return ConnectionTask.fromSocket(ready.future, cancel);
}

/// HttpClient's custom connectionFactory must return an already secure socket
/// for direct HTTPS. It does not add TLS to a supplied plain TCP socket.
Future<ConnectionTask<Socket>> verifiedTlsConnectionTask(
  Future<ConnectionTask<Socket>> opening,
  String hostname, {
  SecurityContext? context,
  bool Function(X509Certificate)? onBadCertificate,
}) async {
  final task = await opening;
  Socket? connection;
  Socket? origin;
  Socket? bridge;
  ServerSocket? server;
  final incoming = <Socket>[];
  Completer<Socket>? waitingBridge;
  var cancelled = false;
  void cancel() {
    cancelled = true;
    task.cancel();
    origin?.destroy();
    bridge?.destroy();
    connection?.destroy();
    for (final peer in incoming) {
      peer.destroy();
    }
    incoming.clear();
    if (waitingBridge != null && !waitingBridge!.isCompleted) {
      waitingBridge!.completeError(
        const SocketException('Connection cancelled'),
      );
    }
    final bound = server;
    if (bound != null) unawaited(bound.close());
  }

  final ready = task.socket.then<Socket>((socket) async {
    origin = socket;
    if (cancelled) {
      socket.destroy();
      throw const SocketException('Connection cancelled');
    }
    // SecureSocket.secure detaches its source TCP socket: destroy() on that
    // old object cannot cancel a pending handshake. Retain the origin through
    // an owned loopback socket pair so cancellation always has a live handle.
    final accepted = Completer<Socket>();
    waitingBridge = accepted;
    accepted.future.ignore();
    Socket? local;
    void select() {
      if (local == null) return;
      for (final peer in incoming) {
        if (!accepted.isCompleted && peer.remotePort == local.port) {
          accepted.complete(peer);
        } else {
          peer.destroy();
        }
      }
      incoming.clear();
    }

    try {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      if (cancelled) throw const SocketException('Connection cancelled');
      server!.listen((peer) {
        if (cancelled || accepted.isCompleted || incoming.length >= 4) {
          peer.destroy();
          return;
        }
        incoming.add(peer);
        select();
      });
      local = await Socket.connect(InternetAddress.loopbackIPv4, server!.port);
      connection = local;
      select();
      bridge = await accepted.future;
      await server!.close();
      if (cancelled) throw const SocketException('Connection cancelled');
      socket.setOption(SocketOption.tcpNoDelay, true);
      bridge!.setOption(SocketOption.tcpNoDelay, true);
      local.setOption(SocketOption.tcpNoDelay, true);
      unawaited(
        Future.any([socket.addStream(bridge!), bridge!.addStream(socket)]).then(
          (_) async {
            try {
              await bridge!.flush().timeout(const Duration(seconds: 1));
            } catch (_) {}
            cancel();
          },
          onError: (Object _) {
            cancel();
          },
        ),
      );
      final tls = await SecureSocket.secure(
        local,
        host: hostname,
        context: context,
        onBadCertificate: onBadCertificate,
      );
      connection = tls;
      if (cancelled) {
        tls.destroy();
        throw const SocketException('Connection cancelled');
      }
      return tls;
    } catch (_) {
      cancel();
      rethrow;
    }
  });
  return ConnectionTask.fromSocket(ready, cancel);
}
