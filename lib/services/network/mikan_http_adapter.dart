import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;

/// Mikan's Cloudflare endpoint can be unreachable through polluted DNS or
/// clear-text TLS SNI even when a browser's encrypted connection works.
/// This adapter is also used by the torrent isolate for .torrent metadata.
class MikanHttpAdapter implements HttpClientAdapter {
  MikanHttpAdapter({
    required HttpClientAdapter fallback,
    required Uri? Function(Uri) proxyForUri,
    this.discoveryTimeout = const Duration(seconds: 8),
    http.Client Function()? createEchClient,
  }) : _fallback = fallback,
       _proxyForUri = proxyForUri,
       _createEchClient = createEchClient;

  final HttpClientAdapter _fallback;
  final Uri? Function(Uri) _proxyForUri;
  final http.Client Function()? _createEchClient;
  final Duration discoveryTimeout;
  http.Client? _client;
  http.Client? _bootstrap;
  final _active = <Completer<void>>{};
  bool _closed = false;

  static bool supports(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host.toLowerCase() == 'mikanani.me' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty;

  http.Client _echClient() => _client ??= _createEchClient?.call() ?? _create();

  http.Client _create() {
    final bootstrap = _bootstrap = EchClient(
      connectTimeout: const Duration(seconds: 3),
      timeout: const Duration(seconds: 5),
    );
    return EchClient(
      resolver: DohEchResolver(
        client: bootstrap,
        endpoint: Uri.https('dns.alidns.com', '/resolve'),
        hosts: const {'mikanani.me'},
        // Cloudflare shares its ECH configuration across these edge addresses.
        // The HTTPS certificate is still verified for mikanani.me.
        configDomains: const {'mikanani.me': 'crypto.cloudflare.com'},
        addressOverrides: const {
          'mikanani.me': ['104.21.17.69', '172.67.223.55'],
        },
      ),
      connectTimeout: const Duration(seconds: 6),
      timeout: const Duration(seconds: 15),
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('Mikan HTTP adapter is closed');
    // Never bypass a user's configured proxy. Only idempotent public-host GETs
    // use automatic ECH; other requests keep their original HTTP transport.
    if (!supports(options.uri) ||
        options.method != 'GET' ||
        _proxyForUri(options.uri) != null) {
      return _fallback.fetch(options, requestStream, cancelFuture);
    }

    final abort = Completer<void>();
    var callerCancelled = false;
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    cancelFuture?.then((_) {
      callerCancelled = true;
      cancel();
    });
    _active.add(abort);
    void release() {
      if (!_active.remove(abort)) return;
      cancel();
      if (_closed && _active.isEmpty) _closeClients();
    }

    try {
      final request =
          http.AbortableRequest('GET', options.uri, abortTrigger: abort.future)
            ..followRedirects = options.followRedirects
            ..maxRedirects = options.maxRedirects
            ..persistentConnection = options.persistentConnection;
      for (final entry in options.headers.entries) {
        if (entry.value != null) {
          request.headers[entry.key] = entry.value is Iterable
              ? (entry.value as Iterable).join(', ')
              : entry.value.toString();
        }
      }
      final response = await _echClient()
          .send(request)
          .timeout(
            discoveryTimeout,
            onTimeout: () {
              cancel();
              throw TimeoutException('Mikan encrypted connection timed out');
            },
          );
      return ResponseBody(
        _body(response.stream, options, release),
        response.statusCode,
        headers: response.headers.map((key, value) => MapEntry(key, [value])),
        statusMessage: response.reasonPhrase,
        isRedirect: response.isRedirect,
        onClose: release,
      );
    } catch (_) {
      release();
      if (callerCancelled || _closed) {
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: 'Mikan request cancelled',
        );
      }
      // Regions without ECH support can still use normal HTTPS. No URL or
      // exception contents are logged: imported personal RSS URLs carry tokens.
      return _fallback.fetch(options, requestStream, cancelFuture);
    }
  }

  Stream<Uint8List> _body(
    Stream<List<int>> source,
    RequestOptions options,
    void Function() release,
  ) async* {
    try {
      await for (final bytes in source) {
        yield bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      }
    } catch (error) {
      if (error is http.RequestAbortedException) {
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: 'Mikan request cancelled',
        );
      }
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Mikan response interrupted',
      );
    } finally {
      release();
    }
  }

  void _closeClients() {
    _client?.close();
    _client = null;
    _bootstrap?.close();
    _bootstrap = null;
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    _fallback.close(force: force);
    if (force) {
      for (final abort in _active) {
        if (!abort.isCompleted) abort.complete();
      }
    }
    if (force || _active.isEmpty) _closeClients();
  }
}
