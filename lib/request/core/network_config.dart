import 'dart:io';
import 'package:dio/dio.dart';

import 'package:dio/io.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/network/public_dns_resolver.dart';
import 'package:kazumi/services/network/mikan_http_adapter.dart';
import 'package:kazumi/services/network/system_proxy_service.dart';
import 'package:kazumi/services/storage/storage.dart';

class NetworkConfig {
  const NetworkConfig({
    this.connectTimeout = const Duration(seconds: 12),
    this.receiveTimeout = const Duration(seconds: 12),
    this.sendTimeout,
    this.proxyHost,
    this.proxyPort,
    this.allowBadCertificates = false,
    this.enableLog = true,
  });

  final Duration connectTimeout;
  final Duration receiveTimeout;
  final Duration? sendTimeout;
  final String? proxyHost;
  final int? proxyPort;
  final bool allowBadCertificates;
  final bool enableLog;

  bool get hasProxy => proxyHost != null && proxyPort != null;

  Uri? proxyForUri(Uri uri) {
    if (hasProxy) return Uri(scheme: 'http', host: proxyHost, port: proxyPort);
    if (Platform.isWindows) {
      final proxy = SystemProxyService.findProxy(uri);
      if (proxy.startsWith('PROXY ')) {
        return Uri.parse('http://${proxy.substring(6)}');
      }
    }
    return null;
  }

  HttpClientAdapter createAdapter() {
    final resolver = PublicDnsResolver(proxyForUri: proxyForUri);
    final fallback = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        // Restrict DNS recovery to known public APIs; personal WebDAV and LAN
        // endpoints keep their existing local DNS and proxy semantics.
        client.connectionFactory = (uri, proxyHost, proxyPort) async {
          if (proxyHost != null)
            return Socket.startConnect(proxyHost, proxyPort!);
          if (!const {
            'bgm.monogatari.top',
            'api.github.com',
            'api.yzzy-api.com',
            'bfzyapi.com',
            'cj.lziapi.com',
          }.contains(uri.host)) {
            return uri.scheme == 'https'
                ? SecureSocket.startConnect(
                    uri.host,
                    uri.port,
                    onBadCertificate: allowBadCertificates ? (_) => true : null,
                  )
                : Socket.startConnect(uri.host, uri.port);
          }
          final addresses = await resolver.lookup(uri.host);
          final opening = publicConnectionTask(addresses, uri.port);
          return uri.scheme == 'https'
              ? verifiedTlsConnectionTask(
                  opening,
                  uri.host,
                  onBadCertificate: allowBadCertificates ? (_) => true : null,
                )
              : opening;
        };
        if (hasProxy) {
          client.findProxy = (_) => 'PROXY $proxyHost:$proxyPort';
        } else if (Platform.isWindows) {
          client.findProxy = SystemProxyService.findProxy;
        }
        if (allowBadCertificates) {
          client.badCertificateCallback = (cert, host, port) => true;
        }
        return client;
      },
    );
    // These public collection APIs also use Cloudflare. A valid-looking but
    // polluted DNS answer or blocked TLS SNI should not make every source time
    // out. Personal endpoints and configured proxies keep their own transport.
    return MikanHttpAdapter(
      fallback: fallback,
      proxyForUri: proxyForUri,
      hosts: const {'api.yzzy-api.com', 'bfzyapi.com', 'cj.lziapi.com'},
    );
  }

  NetworkConfig copyWith({
    Duration? connectTimeout,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    String? proxyHost,
    int? proxyPort,
    bool? clearProxy,
    bool? allowBadCertificates,
    bool? enableLog,
  }) {
    final shouldClearProxy = clearProxy ?? false;
    return NetworkConfig(
      connectTimeout: connectTimeout ?? this.connectTimeout,
      receiveTimeout: receiveTimeout ?? this.receiveTimeout,
      sendTimeout: sendTimeout ?? this.sendTimeout,
      proxyHost: shouldClearProxy ? null : proxyHost ?? this.proxyHost,
      proxyPort: shouldClearProxy ? null : proxyPort ?? this.proxyPort,
      allowBadCertificates: allowBadCertificates ?? this.allowBadCertificates,
      enableLog: enableLog ?? this.enableLog,
    );
  }

  static NetworkConfig fromSettings({
    Duration connectTimeout = const Duration(seconds: 12),
    Duration receiveTimeout = const Duration(seconds: 12),
    Duration? sendTimeout,
  }) {
    final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
    if (!proxyEnable) {
      return NetworkConfig(
        connectTimeout: connectTimeout,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
      );
    }

    final proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
    final parsed = ProxyUtils.parseProxyUrl(proxyUrl);
    if (parsed == null) {
      KazumiLogger().w('Proxy: 代理地址格式错误或为空');
      return NetworkConfig(
        connectTimeout: connectTimeout,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
      );
    }

    return NetworkConfig(
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      sendTimeout: sendTimeout,
      proxyHost: parsed.$1,
      proxyPort: parsed.$2,
      allowBadCertificates: true,
    );
  }
}
