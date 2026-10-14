import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:kazumi/services/api_video/api_video_url_policy.dart';
import 'public_dns_resolver.dart';

/// Cloudflare's published ECH configuration and current edge hints. Discovery
/// contains hostnames only; personal RSS paths and tokens never go to DNS.
class MikanEchDiscovery {
  MikanEchDiscovery({http.Client? client, this.proxyForUri}) : _client = client;

  final Uri? Function(Uri)? proxyForUri;
  http.Client? _client;
  Future<EchRoute>? _pending;
  EchRoute? _cached;
  DateTime? _expires;
  bool _closed = false;

  static final endpoint = Uri.https('dns.alidns.com', '/resolve', {
    'name': 'crypto.cloudflare.com',
    'type': '65',
  });

  http.Client _bootstrap() {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    client.findProxy = (uri) {
      final proxy = proxyForUri?.call(uri);
      return proxy == null ? 'DIRECT' : 'PROXY ${proxy.host}:${proxy.port}';
    };
    client.connectionFactory = (uri, proxyHost, proxyPort) => proxyHost != null
        ? Socket.startConnect(proxyHost, proxyPort!)
        : verifiedTlsConnectionTask(
            Socket.startConnect(InternetAddress('223.5.5.5'), 443),
            uri.host,
          );
    return IOClient(client);
  }

  Future<EchRoute> discover() {
    if (_closed) throw StateError('Mikan discovery is closed');
    if (_cached != null && DateTime.now().isBefore(_expires!)) {
      return Future.value(_cached);
    }
    return _pending ??= _load().whenComplete(() => _pending = null);
  }

  Future<EchRoute> _load() async {
    final client = _client ??= _bootstrap();
    final response = await client
        .send(
          http.Request('GET', endpoint)
            ..headers['accept'] = 'application/dns-json',
        )
        .timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) {
      await response.stream.listen((_) {}).cancel();
      throw const FormatException('Mikan DNS service unavailable');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 4),
    )) {
      if (bytes.length + chunk.length > 16 * 1024) {
        throw const FormatException('Mikan DNS response too large');
      }
      bytes.addAll(chunk);
    }
    final document = jsonDecode(utf8.decode(bytes)) as Map;
    if (document['Status'] != 0) {
      throw const FormatException('Mikan DNS failed');
    }
    for (final record in (document['Answer'] as List? ?? []).whereType<Map>()) {
      if (record['type'] != 65 || record['data'] is! String) continue;
      final text = record['data'] as String;
      final config = RegExp(
        r'(?:^|\s)ech="?([A-Za-z0-9+/=]+)',
      ).firstMatch(text)?[1];
      if (config == null) continue;
      final hint = RegExp(r'(?:^|\s)ipv4hint="?([^"\s]+)').firstMatch(text)?[1];
      final addresses = <String>[];
      for (final value in hint?.split(',') ?? const <String>[]) {
        final address = InternetAddress.tryParse(value);
        if (address != null && isPublicVideoAddress(address)) {
          addresses.add(value);
        }
      }
      if (addresses.isEmpty) {
        throw const FormatException('No usable Mikan edge');
      }
      final route = EchRoute(
        configList: config,
        addresses: addresses.take(4).toList(),
      );
      final ttl = ((record['TTL'] as num?)?.toInt() ?? 0).clamp(0, 300);
      _cached = route;
      _expires = DateTime.now().add(Duration(seconds: ttl));
      return route;
    }
    throw const FormatException('Mikan ECH configuration unavailable');
  }

  void close() {
    _closed = true;
    _client?.close();
  }
}

class MikanEchResolver implements EchResolver {
  MikanEchResolver(
    this.discovery,
    this.addressIndex, {
    this.hosts = const {'mikanani.me'},
  });
  final MikanEchDiscovery discovery;
  final int addressIndex;
  final Set<String> hosts;

  @override
  Future<EchRoute?> resolve(Uri uri) async {
    if (uri.scheme != 'https' || !hosts.contains(uri.host) || uri.port != 443) {
      return null;
    }
    final route = await discovery.discover();
    return EchRoute(
      configList: route.configList,
      addresses: [route.addresses[addressIndex % route.addresses.length]],
    );
  }
}
