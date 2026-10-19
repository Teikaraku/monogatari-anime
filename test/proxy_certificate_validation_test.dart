import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/network/proxy_aware_image_cache_manager.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

class _TrustedClients extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(
        SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates('test/support/tls/server.pem'),
      );
}

void main() {
  late Directory directory;
  late PathProviderPlatform paths;
  late HttpServer origin, proxy;
  final sockets = <Socket>[];
  var tunnels = 0, requests = 0;
  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('monogatari_proxy_tls_');
    paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
    await GStorage.putSetting(SettingsKeys.proxyEnable, true);
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = paths;
    expect(
      directory.absolute.path.startsWith(Directory.systemTemp.absolute.path),
      true,
    );
    expect(
      directory.uri.pathSegments.where((p) => p.isNotEmpty).last,
      startsWith('monogatari_proxy_tls_'),
    );
    await directory.delete(recursive: true);
  });
  setUp(() async {
    tunnels = requests = 0;
    origin = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain('test/support/tls/server.pem')
        ..usePrivateKey('test/support/tls/server.key'),
    );
    origin.listen((request) async {
      requests++;
      request.response.write('verified response');
      await request.response.close();
    }, onError: (Object _) {});
    proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    proxy.listen((request) async {
      expect(request.method, 'CONNECT');
      tunnels++;
      final upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        origin.port,
      );
      final downstream = await request.response.detachSocket(
        writeHeaders: false,
      );
      sockets.addAll([upstream, downstream]);
      downstream.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      await downstream.flush();
      upstream.listen(
        downstream.add,
        onError: (Object _) => downstream.destroy(),
        onDone: downstream.destroy,
      );
      downstream.listen(
        upstream.add,
        onError: (Object _) => upstream.destroy(),
        onDone: upstream.destroy,
      );
    });
    await GStorage.putSetting(SettingsKeys.proxyUrl, '127.0.0.1:${proxy.port}');
  });
  tearDown(() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
    await proxy.close(force: true);
    await origin.close(force: true);
  });

  for (final images in [false, true]) {
    Future<void> request(String host) async {
      final url = 'https://$host:${origin.port}/test';
      if (images) {
        final response = await ProxyAwareImageCacheManager
            .instance
            .config
            .fileService
            .get(url);
        await response.content.drain<void>();
      } else {
        final dio = DioFactory.createForConfig(
          NetworkConfig.fromSettings().copyWith(enableLog: false),
        );
        try {
          await dio.get<String>(url);
        } finally {
          dio.close(force: true);
        }
      }
    }

    test(
      '${images ? 'images' : 'API'} rejects an untrusted certificate through the configured proxy',
      () async {
        await expectLater(
          request('cdn.test').timeout(const Duration(seconds: 4)),
          throwsA(
            predicate<Object>(
              (error) =>
                  error.toString().contains('CERTIFICATE_VERIFY_FAILED') ||
                  error is DioException && error.error is HandshakeException,
            ),
          ),
        );
        expect(tunnels, 1);
        expect(requests, 0);
      },
    );
    test(
      '${images ? 'images' : 'API'} accepts trusted TLS through the configured proxy',
      () async {
        await HttpOverrides.runWithHttpOverrides(
          () => request('cdn.test').timeout(const Duration(seconds: 4)),
          _TrustedClients(),
        );
        expect(tunnels, 1);
        expect(requests, 1);
      },
    );
    test(
      '${images ? 'images' : 'API'} rejects a trusted certificate for the wrong host',
      () async {
        await expectLater(
          HttpOverrides.runWithHttpOverrides(
            () =>
                request('wrong-host.test').timeout(const Duration(seconds: 4)),
            _TrustedClients(),
          ),
          throwsA(
            predicate<Object>(
              (error) =>
                  error.toString().contains('CERTIFICATE_VERIFY_FAILED') ||
                  error is DioException && error.error is HandshakeException,
            ),
          ),
        );
        expect(tunnels, 1);
        expect(requests, 0);
      },
    );
  }
}
