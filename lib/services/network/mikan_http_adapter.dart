import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;
import 'mikan_ech_resolver.dart';
import 'public_metadata_relay.dart';

/// Mikan's Cloudflare endpoint can be unreachable through polluted DNS or
/// clear-text TLS SNI even when a browser's encrypted connection works.
/// This adapter is also used by the torrent isolate for .torrent metadata.
class MikanHttpAdapter implements HttpClientAdapter {
  MikanHttpAdapter({
    required HttpClientAdapter fallback,
    required Uri? Function(Uri) proxyForUri,
    this.discoveryTimeout = const Duration(seconds: 8),
    this.hedgeDelay = const Duration(milliseconds: 250),
    this.hosts = const {'mikanani.me'},
    this.maxResponseBytes = 8 * 1024 * 1024,
    this.enablePublicRelay = true,
    http.Client Function()? createEchClient,
    http.Client Function()? createSecondaryEchClient,
  }) : _fallback = fallback,
       _proxyForUri = proxyForUri,
       _createEchClient = createEchClient,
       _createSecondaryEchClient = createSecondaryEchClient;

  final HttpClientAdapter _fallback;
  final Uri? Function(Uri) _proxyForUri;
  final http.Client Function()? _createEchClient;
  final http.Client Function()? _createSecondaryEchClient;
  final Duration discoveryTimeout;
  final Duration hedgeDelay;
  final int maxResponseBytes;
  final bool enablePublicRelay;

  /// Only explicitly configured Cloudflare hosts use the encrypted transport.
  final Set<String> hosts;
  http.Client? _client;
  http.Client? _secondary;
  MikanEchDiscovery? _discovery;
  final _active = <Completer<void>>{};
  final _publicRequests = <Completer<void>>{};
  bool _closed = false;

  static bool supports(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host.toLowerCase() == 'mikanani.me' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty;

  http.Client _echClient() =>
      _client ??= _createEchClient?.call() ?? _create(0);

  http.Client _create(int index) {
    final discovery = _discovery ??= MikanEchDiscovery(
      proxyForUri: _proxyForUri,
    );
    return EchClient(
      resolver: MikanEchResolver(discovery, index, hosts: hosts),
      connectTimeout: const Duration(seconds: 3),
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
    final relay = enablePublicRelay && _proxyForUri(options.uri) == null
        ? publicMetadataRelayUri(options)
        : null;
    if (relay != null && hosts.contains(options.uri.host)) {
      final abort = Completer<void>();
      _publicRequests.add(abort);
      cancelFuture?.then((_) {
        if (!abort.isCompleted) abort.complete();
      });
      try {
        return await racePublicMetadata(
          request: options,
          origin: (cancel) => _fetchOrigin(options, requestStream, cancel),
          relay: (cancel) => _fallback.fetch(
            options.copyWith(
              path: relay.toString(),
              baseUrl: '',
              queryParameters: {},
              headers: const {
                'user-agent': 'Monogatari',
                'accept-encoding': 'gzip',
              },
            ),
            null,
            cancel,
          ),
          cancelFuture: abort.future,
          maxBytes: maxResponseBytes,
        );
      } finally {
        _publicRequests.remove(abort);
        if (!abort.isCompleted) abort.complete();
      }
    }
    return _fetchOrigin(options, requestStream, cancelFuture);
  }

  Future<ResponseBody> _fetchOrigin(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('Mikan HTTP adapter is closed');
    // Never bypass a user's configured proxy. Only idempotent public-host GETs
    // use automatic ECH; other requests keep their original HTTP transport.
    if (options.uri.scheme != 'https' ||
        options.uri.port != 443 ||
        options.uri.userInfo.isNotEmpty ||
        !hosts.contains(options.uri.host.toLowerCase()) ||
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
      final response = await _sendEncrypted(options, abort).timeout(
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

  Future<http.StreamedResponse> _sendEncrypted(
    RequestOptions options,
    Completer<void> abort,
  ) async {
    final ready = Completer<http.StreamedResponse>();
    final attempts = <Completer<void>>[];
    final hasSecondary =
        _createEchClient == null || _createSecondaryEchClient != null;
    var failures = 0;
    var secondaryStarted = false;
    Timer? hedge;
    void cancel(Completer<void> attempt) {
      if (!attempt.isCompleted) attempt.complete();
    }

    Future<void> send(http.Client client) async {
      final attempt = Completer<void>();
      attempts.add(attempt);
      unawaited(abort.future.then((_) => cancel(attempt)));
      try {
        final request =
            http.AbortableRequest(
                'GET',
                options.uri,
                abortTrigger: attempt.future,
              )
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
        final response = await client.send(request);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.stream.listen((_) {}).cancel();
          throw http.ClientException('Mikan encrypted endpoint unavailable');
        }
        // A fast 200 header is not a usable result if that edge never delivers
        // its body. Race complete, bounded documents instead of cancelling a
        // healthy backup as soon as the first response headers arrive.
        final content = BytesBuilder(copy: false);
        await for (final bytes in response.stream.timeout(
          options.receiveTimeout ?? discoveryTimeout,
        )) {
          if (content.length + bytes.length > maxResponseBytes) {
            throw http.ClientException('Encrypted response too large');
          }
          content.add(bytes);
        }
        if (ready.isCompleted || abort.isCompleted) {
          cancel(attempt);
          return;
        }
        hedge?.cancel();
        for (final other in attempts) {
          if (!identical(other, attempt)) cancel(other);
        }
        ready.complete(
          http.StreamedResponse(
            Stream.value(content.takeBytes()),
            response.statusCode,
            headers: response.headers,
            contentLength: response.contentLength,
            reasonPhrase: response.reasonPhrase,
            isRedirect: response.isRedirect,
            request: response.request,
          ),
        );
      } catch (error, stack) {
        cancel(attempt);
        failures++;
        if (failures == (hasSecondary ? 2 : 1) && !ready.isCompleted) {
          ready.completeError(error, stack);
        }
      }
    }

    unawaited(send(_echClient()));
    if (hasSecondary) {
      hedge = Timer(hedgeDelay, () {
        if (ready.isCompleted || abort.isCompleted || secondaryStarted) return;
        secondaryStarted = true;
        try {
          _secondary ??= _createSecondaryEchClient?.call() ?? _create(1);
          unawaited(send(_secondary!));
        } catch (error, stack) {
          if (++failures == 2 && !ready.isCompleted) {
            ready.completeError(error, stack);
          }
        }
      });
    }
    unawaited(
      abort.future.then((_) {
        hedge?.cancel();
        if (!ready.isCompleted) {
          ready.completeError(http.RequestAbortedException(options.uri));
        }
      }),
    );
    return ready.future;
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
    _secondary?.close();
    _secondary = null;
    _discovery?.close();
    _discovery = null;
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    _fallback.close(force: force);
    if (force) {
      for (final abort in _publicRequests) {
        if (!abort.isCompleted) abort.complete();
      }
      for (final abort in _active) {
        if (!abort.isCompleted) abort.complete();
      }
    }
    if (force || _active.isEmpty) _closeClients();
  }
}
