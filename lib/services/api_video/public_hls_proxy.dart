import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'api_video_url_policy.dart';
import 'public_video_proxy.dart';
import 'package:kazumi/utils/m3u8_ad_filter.dart';

/// Browser-like HTTP pooling and a four-segment lookahead for short VOD
/// segments. Everything is scoped to one player and retained only in memory.
class PublicHlsProxy {
  PublicHlsProxy({
    required this.source,
    this.headers = const {},
    this.proxyForUri,
    this.lookahead = 4,
    this.maxSegmentBytes = 8 * 1024 * 1024,
    this.maxCacheBytes = 32 * 1024 * 1024,
    this.onFetch,
    this.onFailure,
    this.adBlockerEnabled = false,
    HttpClient? client,
    bool Function(Uri)? allowUri,
  }) : _injectedClient = client,
       _allowUri = allowUri ?? isPublicVideoUri;

  final Uri source;
  final Map<String, String> headers;
  final Uri? Function(Uri)? proxyForUri;
  final int lookahead;
  final int maxSegmentBytes;
  final int maxCacheBytes;
  final bool adBlockerEnabled;
  final void Function(Uri uri, int milliseconds, int bytes)? onFetch;
  final void Function(Uri uri, Object error)? onFailure;
  final HttpClient? _injectedClient;
  final bool Function(Uri) _allowUri;
  final _scope = base64Url.encode(
    List.generate(24, (_) => Random.secure().nextInt(256)),
  );
  final _resources = <String, _HlsResource>{};
  final _ids = <Uri, String>{};
  final _cache = <String, Uint8List>{};
  final _pending = <String, Future<Uint8List?>>{};
  final _uncacheable = <String>{};
  final _responseUris = Expando<Uri>();
  final _clients = <HttpRequest>{};
  late HttpClient _client;
  PublicVideoProxy? _route;
  HttpServer? _server;
  bool _closed = false;
  bool _clientReady = false;
  int _cacheBytes = 0;
  int get cachedBytes => _cacheBytes;
  Uri get uri => _local(_ids[source]!);

  Future<void> start() async {
    if (!_allowUri(source)) throw const FormatException('播放地址不符合安全要求');
    try {
      if (_injectedClient != null) {
        _client = _injectedClient;
      } else {
        final route = _route = PublicVideoProxy(proxyForUri: proxyForUri);
        await route.start();
        _client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 8)
          ..maxConnectionsPerHost = lookahead
          ..idleTimeout = const Duration(seconds: 30);
        _client.findProxy = (_) => 'DIRECT';
        _client.connectionFactory = (uri, _, _) =>
            route.secureConnectionTask(uri);
      }
      _clientReady = true;
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _register(source, playlist: true);
      _server!.listen(
        (request) => unawaited(_serve(request).catchError((Object _) {})),
      );
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Uri _local(String id) =>
      Uri.parse('http://127.0.0.1:${_server!.port}/$_scope/$id');

  String _register(Uri url, {bool playlist = false, bool prefetch = false}) {
    if (!_allowUri(url)) throw const FormatException('清单包含不安全的地址');
    final existing = _ids[url];
    if (existing != null) return existing;
    if (_resources.length >= 10000) throw const FormatException('播放清单过大');
    final id = '${_resources.length}';
    _ids[url] = id;
    _resources[id] = _HlsResource(url, playlist, prefetch);
    return id;
  }

  Future<HttpClientResponse> _get(Uri uri, {String? range}) async {
    for (var redirects = 0; redirects <= 4; redirects++) {
      if (_closed) throw const HttpException('Playback closed');
      if (!_allowUri(uri)) throw const FormatException('片源重定向到不安全地址');
      final request = await _client
          .getUrl(uri)
          .timeout(const Duration(seconds: 8));
      if (_closed) {
        request.abort();
        throw const HttpException('Playback closed');
      }
      request.followRedirects = false;
      for (final header in headers.entries) {
        request.headers.set(header.key, header.value);
      }
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      final response = await request.close().timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          final error = TimeoutException('Video response headers timed out');
          request.abort(error);
          throw error;
        },
      );
      if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.listen((_) {}).cancel();
        if (location == null) throw const HttpException('Missing redirect');
        uri = uri.resolve(location);
        continue;
      }
      _responseUris[response] = uri;
      return response;
    }
    throw const HttpException('Too many redirects');
  }

  Future<Uint8List> _read(HttpClientResponse response, int limit) async {
    if (response.statusCode != 200) {
      await response.listen((_) {}).cancel();
      throw HttpException('Video response ${response.statusCode}');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 12))) {
      if (_closed || bytes.length + chunk.length > limit) {
        throw const _ResourceTooLarge();
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<Uint8List?> _segment(String id) {
    if (_uncacheable.contains(id)) return Future.value(null);
    final cached = _cache.remove(id);
    if (cached != null) {
      _cache[id] = cached;
      return Future.value(cached);
    }
    return _pending.putIfAbsent(id, () async {
      final clock = Stopwatch()..start();
      try {
        final response = await _get(_resources[id]!.url);
        if (response.contentLength > maxSegmentBytes) {
          await response.listen((_) {}).cancel();
          _uncacheable.add(id);
          return null;
        }
        final bytes = await _read(response, maxSegmentBytes);
        onFetch?.call(
          _resources[id]!.url,
          clock.elapsedMilliseconds,
          bytes.length,
        );
        if (_closed) return null;
        while (_cache.isNotEmpty &&
            _cacheBytes + bytes.length > maxCacheBytes) {
          final oldest = _cache.keys.first;
          _cacheBytes -= _cache.remove(oldest)!.length;
        }
        if (bytes.length <= maxCacheBytes) {
          _cache[id] = bytes;
          _cacheBytes += bytes.length;
        }
        return bytes;
      } on _ResourceTooLarge {
        _uncacheable.add(id);
        return null;
      } catch (error) {
        if (!_closed) onFailure?.call(_resources[id]!.url, error);
        rethrow;
      } finally {
        _pending.remove(id);
      }
    });
  }

  void _lookAhead(_HlsResource resource) {
    final group = resource.group;
    if (group == null || resource.index < 0) return;
    for (final id in group.skip(resource.index + 1).take(lookahead - 1)) {
      if (_closed || _pending.length >= lookahead) break;
      if (!_resources[id]!.prefetch ||
          _cache.containsKey(id) ||
          _pending.containsKey(id))
        continue;
      // A speculative failure does not fail the requested segment. The actual
      // player request retries it or continues to the next provider normally.
      unawaited(_segment(id).then<void>((_) {}, onError: (Object _) {}));
    }
  }

  Future<String> _playlist(_HlsResource resource) async {
    final response = await _get(resource.url);
    final effective = _responseUris[response]!;
    var raw = utf8.decode(await _read(response, 1024 * 1024));
    if (!raw.trimLeft().startsWith('#EXTM3U'))
      throw const FormatException('不是有效的视频清单');
    if (adBlockerEnabled)
      raw = M3u8AdFilter.filterPlaylist(raw, effective.toString());
    final out = <String>[];
    final segments = <String>[];
    var variant = false;
    var ranged = false;
    for (final line in const LineSplitter().convert(raw)) {
      final text = line.trim();
      if (text.startsWith('#')) {
        variant = text.startsWith('#EXT-X-STREAM-INF') || variant;
        if (text.startsWith('#EXT-X-BYTERANGE')) ranged = true;
        final rewritten = line.replaceAllMapped(RegExp(r'URI="([^"]+)"'), (
          match,
        ) {
          final url = effective.resolve(match[1]!);
          final playlist =
              text.startsWith('#EXT-X-MEDIA:') ||
              text.startsWith('#EXT-X-I-FRAME-STREAM-INF:') ||
              url.path.endsWith('.m3u8');
          return 'URI="${_local(_register(url, playlist: playlist))}"';
        });
        out.add(rewritten);
      } else if (text.isNotEmpty) {
        final url = effective.resolve(text);
        final playlist = variant || url.path.endsWith('.m3u8');
        final id = _register(
          url,
          playlist: playlist,
          prefetch: !playlist && !ranged,
        );
        if (!playlist) segments.add(id);
        out.add(_local(id).toString());
        variant = false;
        ranged = false;
      } else {
        out.add(line);
      }
    }
    for (var i = 0; i < segments.length; i++) {
      final segment = _resources[segments[i]]!;
      segment.group = segments;
      segment.index = i;
    }
    return '${out.join('\n')}\n';
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final parts = request.uri.pathSegments;
    final resource = parts.length == 2 && parts.first == _scope
        ? _resources[parts.last]
        : null;
    if (_closed ||
        resource == null ||
        request.headers.value('origin') != null ||
        request.headers.value('host') != '127.0.0.1:${_server!.port}') {
      response.statusCode = 404;
      await response.close();
      return;
    }
    if (!const {'GET', 'HEAD'}.contains(request.method) ||
        _clients.length >= 12) {
      response.statusCode = 503;
      await response.close();
      return;
    }
    _clients.add(request);
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    try {
      if (resource.playlist) {
        final bytes = utf8.encode(await _playlist(resource));
        response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        response.contentLength = bytes.length;
        if (request.method == 'GET') response.add(bytes);
      } else {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (resource.prefetch && request.method == 'GET') {
          final pending = _segment(parts.last);
          _lookAhead(resource);
          final bytes = await pending;
          if (bytes != null) {
            final selection = _range(range, bytes.length);
            if (selection == null) {
              response.statusCode = 416;
              response.headers.set(
                HttpHeaders.contentRangeHeader,
                'bytes */${bytes.length}',
              );
              return;
            }
            response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
            response.contentLength = selection.$2 - selection.$1 + 1;
            if (range != null) {
              response.statusCode = 206;
              response.headers.set(
                HttpHeaders.contentRangeHeader,
                'bytes ${selection.$1}-${selection.$2}/${bytes.length}',
              );
            }
            response.add(
              Uint8List.sublistView(bytes, selection.$1, selection.$2 + 1),
            );
            return;
          }
        }
        final origin = await _get(resource.url, range: range);
        response.statusCode = origin.statusCode;
        for (final name in [
          HttpHeaders.contentTypeHeader,
          HttpHeaders.contentRangeHeader,
          HttpHeaders.acceptRangesHeader,
        ]) {
          final value = origin.headers.value(name);
          if (value != null) response.headers.set(name, value);
        }
        if (origin.compressionState !=
            HttpClientResponseCompressionState.decompressed) {
          response.contentLength = origin.contentLength;
        }
        if (request.method == 'HEAD') {
          await origin.listen((_) {}).cancel();
        } else {
          await response.addStream(origin.timeout(const Duration(seconds: 12)));
        }
      }
    } catch (error) {
      onFailure?.call(resource.url, error);
      try {
        response.statusCode = 502;
      } catch (_) {}
    } finally {
      _clients.remove(request);
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    _closed = true;
    if (_clientReady) _client.close(force: true);
    await _route?.close();
    await _server?.close(force: true);
    _cache.clear();
    _cacheBytes = 0;
  }

  static (int, int)? _range(String? range, int size) {
    if (size <= 0) return null;
    if (range == null) return (0, size - 1);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
    if (match == null) return null;
    final start = int.tryParse(match[1]!);
    final end = int.tryParse(match[2]!);
    if (start == null) {
      if (end == null || end <= 0) return null;
      return (max(0, size - end), size - 1);
    }
    if (start >= size || (end != null && end < start)) return null;
    return (start, min(end ?? size - 1, size - 1));
  }
}

class _ResourceTooLarge implements Exception {
  const _ResourceTooLarge();
}

class _HlsResource {
  _HlsResource(this.url, this.playlist, this.prefetch);
  final Uri url;
  final bool playlist;
  final bool prefetch;
  List<String>? group;
  int index = -1;
}
