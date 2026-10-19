import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/config/public_origins.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:kazumi/services/network/bangumi_ech_resolver.dart';

const _echRequestKey = 'bangumiEch';
const _originalRequestKey = 'bangumiOriginalApi';

class BangumiAccelerationInterceptor extends Interceptor {
  BangumiAccelerationInterceptor({this.relayOrigin = publicCatalogOrigin});

  final String relayOrigin;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra.remove(_echRequestKey);
    options.extra.remove(_originalRequestKey);
    final uri = options.uri;
    if (ApiEndpoints.bangumiPublicApiHosts.contains(uri.host)) {
      switch (BangumiAcceleration.current) {
        case BangumiAcceleration.direct:
          break;
        case BangumiAcceleration.ech:
          options.path = uri.replace(scheme: 'https').toString();
          options.queryParameters = {};
          options.extra[_echRequestKey] = true;
        case BangumiAcceleration.mirror:
          final relay = publicCatalogUri(relayOrigin);
          if (relay == null) break;
          options.extra[_originalRequestKey] = uri.toString();
          options.path = relay
              .replace(path: uri.path, query: uri.hasQuery ? uri.query : null)
              .toString();
          options.queryParameters = {};
          KazumiLogger().d('Bangumi mirror: ${options.path}');
      }
    }
    handler.next(options);
  }
}

class BangumiEchAdapter implements HttpClientAdapter {
  BangumiEchAdapter({
    required HttpClientAdapter fallback,
    required NetworkConfig config,
    this.relayOrigin = publicCatalogOrigin,
    http.Client Function(RequestOptions)? echClient,
  }) : _fallback = fallback,
       _config = config,
       _injectedClient = echClient;

  final HttpClientAdapter _fallback;
  final NetworkConfig _config;
  final String relayOrigin;
  final http.Client Function(RequestOptions)? _injectedClient;
  final _races = <Completer<void>>{};
  final _resolvers = <Uri?, DohEchResolver>{};
  final _clients = <(Uri?, Uri?, Duration, Duration), EchClient>{};
  final _activeRequests = <Completer<void>>{};
  bool _closed = false;

  EchClient _clientFor(RequestOptions options) {
    final proxy = _config.proxyForUri(options.uri);
    final dohProxy = _config.proxyForUri(BangumiEchResolver.endpoint);
    final connectTimeout = _positive(
      options.connectTimeout,
      _config.connectTimeout,
    );
    final timeout =
        connectTimeout +
        _positive(options.receiveTimeout, _config.receiveTimeout) +
        _positive(options.sendTimeout, const Duration(seconds: 12));
    // Native timeouts are client-wide; only matching settings share a pool.
    return _clients.putIfAbsent(
      (proxy, dohProxy, connectTimeout, timeout),
      () => EchClient(
        proxy: proxy,
        resolver: _resolvers.putIfAbsent(
          dohProxy,
          () => BangumiEchResolver.create(EchClient(proxy: dohProxy)),
        ),
        connectTimeout: connectTimeout,
        timeout: timeout,
      ),
    );
  }

  static Duration _positive(Duration? value, Duration fallback) =>
      value != null && value > Duration.zero ? value : fallback;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('Bangumi ECH adapter is closed');
    if (options.extra[_echRequestKey] != true) {
      final original = Uri.tryParse(
        options.extra[_originalRequestKey]?.toString() ?? '',
      );
      final recoverable =
          publicCatalogUri(relayOrigin) != null &&
          original != null &&
          ApiEndpoints.bangumiPublicApiHosts.contains(original.host) &&
          !original.path.startsWith('/v0/users/') &&
          original.path != '/v0/me' &&
          options.responseType == ResponseType.json &&
          options.uri.host == publicCatalogUri(relayOrigin)!.host &&
          (options.method == 'GET' && requestStream == null ||
              options.method == 'POST' &&
                  const {
                    '/p1/search/subjects',
                    '/v0/search/subjects',
                  }.contains(original.path)) &&
          !options.headers.keys.any(
            (name) =>
                const {'authorization', 'cookie'}.contains(name.toLowerCase()),
          );
      if (!recoverable) {
        return _fallback.fetch(options, requestStream, cancelFuture);
      }
      final recovery = options.copyWith(
        path: original.toString(),
        baseUrl: '',
        queryParameters: {},
        extra: {...options.extra, _echRequestKey: true},
      );
      return _racePublic(options, recovery, requestStream, cancelFuture);
    }

    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    cancelFuture?.then((_) => cancel());
    _activeRequests.add(abort);
    void release() {
      if (!_activeRequests.remove(abort)) return;
      cancel();
      if (_closed && _activeRequests.isEmpty) _closeClients();
    }

    try {
      final client = _injectedClient?.call(options) ?? _clientFor(options);
      final request =
          _EchRequest(options.method, options.uri, requestStream, abort.future)
            ..followRedirects = options.followRedirects
            ..maxRedirects = options.maxRedirects
            ..persistentConnection = options.persistentConnection;
      for (final entry in options.headers.entries) {
        final value = entry.value;
        if (value != null) {
          request.headers[entry.key] = value is Iterable
              ? value.join(', ')
              : value.toString();
        }
      }
      // Native connect timeouts exclude DoH discovery.
      final timeout =
          _positive(options.connectTimeout, _config.connectTimeout) +
          _positive(options.receiveTimeout, _config.receiveTimeout);
      final response = await client
          .send(request)
          .timeout(
            timeout,
            onTimeout: () {
              cancel();
              throw DioException.receiveTimeout(
                timeout: timeout,
                requestOptions: options,
              );
            },
          );
      return ResponseBody(
        _responseStream(response.stream, options, release),
        response.statusCode,
        headers: response.headers.map((key, value) => MapEntry(key, [value])),
        statusMessage: response.reasonPhrase,
        isRedirect: response.isRedirect,
        onClose: release,
      );
    } catch (error, stackTrace) {
      release();
      throw _mapError(error, stackTrace, options);
    }
  }

  /// Race complete documents: a fast error page or a header followed by a
  /// stalled body must not cancel a working route. Only public reads and the
  /// explicitly allowlisted read-only search POST can be replayed.
  Future<ResponseBody> _racePublic(
    RequestOptions mirror,
    RequestOptions official,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final abort = Completer<void>();
    _races.add(abort);
    final ready = Completer<ResponseBody>();
    ready.future.ignore();
    final attempts = [Completer<void>(), Completer<void>()];
    void cancel() {
      for (final attempt in attempts) {
        if (!attempt.isCompleted) attempt.complete();
      }
      if (!ready.isCompleted) {
        ready.completeError(
          DioException.requestCancelled(
            requestOptions: mirror,
            reason: 'Bangumi request cancelled',
          ),
        );
      }
    }

    unawaited(abort.future.then((_) => cancel()));
    if (cancelFuture != null) {
      unawaited(
        cancelFuture.then((_) {
          if (!abort.isCompleted) abort.complete();
        }),
      );
    }
    var failed = 0;
    try {
      Uint8List? body;
      if (requestStream != null) {
        body = await _boundedBytes(
          requestStream,
          _positive(mirror.sendTimeout, const Duration(seconds: 8)),
        );
      }
      if (abort.isCompleted) return await ready.future;
      Future<void> send(int index, RequestOptions options) async {
        final attempt = attempts[index];
        try {
          final response =
              await (index == 0
                      ? _fallback.fetch(
                          options,
                          body == null ? null : Stream.value(body),
                          attempt.future,
                        )
                      : fetch(
                          options,
                          body == null ? null : Stream.value(body),
                          attempt.future,
                        ))
                  .then((response) async {
                    if (response.statusCode < 200 ||
                        response.statusCode >= 300) {
                      await response.stream.listen((_) {}).cancel();
                      throw DioException.badResponse(
                        statusCode: response.statusCode,
                        requestOptions: options,
                        response: Response(
                          requestOptions: options,
                          statusCode: response.statusCode,
                        ),
                      );
                    }
                    final bytes = await _boundedBytes(
                      response.stream,
                      _positive(options.receiveTimeout, _config.receiveTimeout),
                    );
                    // Public catalog routes return JSON, never HTML challenges.
                    final path = options.uri.path;
                    final valid = bytes.length > 64 * 1024
                        ? await compute(_validateCatalogPayload, (bytes, path))
                        : _validCatalogDocument(bytes, path);
                    if (!valid) {
                      throw const FormatException(
                        'Invalid Bangumi catalog document',
                      );
                    }
                    return ResponseBody(
                      Stream.value(bytes),
                      response.statusCode,
                      headers: response.headers,
                      statusMessage: response.statusMessage,
                      isRedirect: response.isRedirect,
                    );
                  })
                  .timeout(
                    _positive(options.connectTimeout, _config.connectTimeout) +
                        _positive(
                          options.receiveTimeout,
                          _config.receiveTimeout,
                        ),
                  );
          if (ready.isCompleted || abort.isCompleted) return;
          ready.complete(response);
          // Cancels the other route's socket, body read and ECH discovery.
          final loser = attempts[1 - index];
          if (!loser.isCompleted) loser.complete();
        } catch (error, stack) {
          if (!attempt.isCompleted) attempt.complete();
          if (++failed == 2 && !ready.isCompleted) {
            ready.completeError(_mapError(error, stack, mirror), stack);
          }
        }
      }

      unawaited(send(0, mirror));
      unawaited(send(1, official));
      return await ready.future;
    } finally {
      _races.remove(abort);
      if (!abort.isCompleted) abort.complete();
      for (final attempt in attempts) {
        if (!attempt.isCompleted) attempt.complete();
      }
    }
  }

  static Future<Uint8List> _boundedBytes(
    Stream<Uint8List> stream,
    Duration timeout,
  ) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream.timeout(timeout)) {
      if (bytes.length + chunk.length > 8 * 1024 * 1024) {
        throw const FormatException('Bangumi response exceeds 8 MiB');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  static bool _validCatalogDocument(Uint8List bytes, String path) {
    final data = jsonDecode(utf8.decode(bytes));
    if (path == '/p1/calendar') {
      return data is Map &&
          List.generate(7, (i) => '${i + 1}').every((day) => data[day] is List);
    }
    if (path.endsWith('/episodes') ||
        path.contains('/search/') ||
        path == '/p1/trending/subjects') {
      return data is Map && data['data'] is List && data['total'] is num;
    }
    if (RegExp(r'^/(p1|v0)/subjects/\d+$').hasMatch(path)) {
      return data is Map && data['id'] is num;
    }
    return data is Map || data is List;
  }

  // A tear-off and a data-only message keep request completers, streams and
  // native clients out of the worker isolate's captured context.
  static bool _validateCatalogPayload((Uint8List, String) payload) =>
      _validCatalogDocument(payload.$1, payload.$2);

  Stream<Uint8List> _responseStream(
    Stream<List<int>> stream,
    RequestOptions options,
    void Function() release,
  ) async* {
    try {
      await for (final chunk in stream) {
        yield chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      }
    } catch (error, stackTrace) {
      throw _mapError(error, stackTrace, options);
    } finally {
      release();
    }
  }

  DioException _mapError(
    Object error,
    StackTrace stack,
    RequestOptions options,
  ) {
    if (error is DioException) return error;
    if (error is http.RequestAbortedException) {
      return DioException.requestCancelled(
        requestOptions: options,
        reason: error,
        stackTrace: stack,
      );
    }
    if (error is TimeoutException ||
        error is EchException && error.nativeCode == 28) {
      return DioException.receiveTimeout(
        requestOptions: options,
        timeout: options.receiveTimeout ?? _config.receiveTimeout,
        error: error,
      );
    }
    return DioException.connectionError(
      requestOptions: options,
      reason: error.toString(),
      error: error,
      stackTrace: stack,
    );
  }

  void _closeClients() {
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
    for (final resolver in _resolvers.values) {
      resolver.client.close();
    }
    _resolvers.clear();
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    if (force) {
      for (final race in _races) {
        if (!race.isCompleted) race.complete();
      }
      for (final request in _activeRequests.toList()) {
        if (!request.isCompleted) request.complete();
      }
    }
    _fallback.close(force: force);
    if (force || _activeRequests.isEmpty) _closeClients();
  }
}

class _EchRequest extends http.BaseRequest with http.Abortable {
  _EchRequest(super.method, super.url, this._stream, this.abortTrigger);

  final Stream<Uint8List>? _stream;
  @override
  final Future<void> abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_stream ?? const Stream.empty());
  }
}
