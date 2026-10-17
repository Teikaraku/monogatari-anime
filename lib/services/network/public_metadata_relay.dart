import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:b_encode_decode/b_encode_decode.dart' as bencode;
import 'package:kazumi/request/config/public_origins.dart';
import 'package:xml/xml.dart';

/// Only public, read-only catalog requests may use the application's relay.
/// Personal RSS, cookies, tokens, arbitrary hosts and media are excluded.
Uri? publicMetadataRelayUri(RequestOptions request) {
  final uri = request.uri;
  if (request.method != 'GET' ||
      uri.scheme != 'https' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      request.headers.keys.any(
        (key) => const {'authorization', 'cookie'}.contains(key.toLowerCase()),
      )) {
    return null;
  }
  final query = uri.queryParametersAll;
  if (query.values.any((values) => values.length != 1)) return null;
  bool keys(Set<String> allowed) => query.keys.every(allowed.contains);
  bool positive(String key) =>
      RegExp(r'^\d{1,10}$').hasMatch(uri.queryParameters[key] ?? '');
  String? path;
  if (uri.host == 'mikanani.me') {
    if (uri.path == '/Home/Search' &&
        keys({'searchstr'}) &&
        (uri.queryParameters['searchstr']?.length ?? 0) <= 100) {
      path = '/public/mikan/Home/Search';
    } else if (uri.path == '/RSS/Bangumi' &&
        keys({'bangumiId', 'subgroupid'}) &&
        positive('bangumiId') &&
        (!query.containsKey('subgroupid') || positive('subgroupid'))) {
      path = '/public/mikan/RSS/Bangumi';
    } else if (query.isEmpty &&
        RegExp(
          r'^/(?:Home/Bangumi/\d{1,10}|Home/Episode/[a-fA-F0-9]{40}|Download/\d{8}/[a-fA-F0-9]{40}\.torrent)/?$',
        ).hasMatch(uri.path)) {
      path = '/public/mikan${uri.path}';
    }
  } else {
    final provider = switch ((uri.host, uri.path)) {
      ('api.yzzy-api.com', '/inc/apijson.php') => '1080',
      ('bfzyapi.com', '/api.php/provide/vod/') => 'baofeng',
      ('cj.lziapi.com', '/api.php/provide/vod/') => 'liangzi',
      _ => null,
    };
    if (provider != null &&
        keys({'ac', 'wd', 'pg', 'ids'}) &&
        uri.queryParameters['ac'] == 'detail' &&
        (uri.queryParameters['wd']?.length ?? 0) <= 200 &&
        (!query.containsKey('pg') || positive('pg')) &&
        (!query.containsKey('ids') ||
            RegExp(r'^\d+(?:,\d+)*$').hasMatch(uri.queryParameters['ids']!))) {
      path = '/public/vod/$provider';
    }
  }
  return path == null
      ? null
      : Uri.parse(publicCatalogOrigin).replace(
          path: path,
          queryParameters: query.isEmpty
              ? null
              : {
                  // Imported feeds can put the subgroup first. The relay uses one
                  // canonical query order for its allowlist and cache key.
                  if (query.containsKey('bangumiId'))
                    'bangumiId': uri.queryParameters['bangumiId']!,
                  if (query.containsKey('subgroupid'))
                    'subgroupid': uri.queryParameters['subgroupid']!,
                  ...Map.fromEntries(
                    uri.queryParameters.entries.where(
                      (entry) =>
                          entry.key != 'bangumiId' && entry.key != 'subgroupid',
                    ),
                  ),
                },
        );
}

typedef MetadataFetch = Future<ResponseBody> Function(Future<void> cancel);

/// Race complete bounded bodies, so a fast 403/HTML error cannot hide a
/// healthy route. Every losing socket/body and a cancelled caller are stopped.
Future<ResponseBody> racePublicMetadata({
  required RequestOptions request,
  required MetadataFetch origin,
  required MetadataFetch relay,
  Future<void>? cancelFuture,
  required int maxBytes,
}) async {
  final ready = Completer<ResponseBody>();
  final aborts = [Completer<void>(), Completer<void>()];
  var failed = 0;
  void stop() {
    for (final abort in aborts) {
      if (!abort.isCompleted) abort.complete();
    }
  }

  cancelFuture?.then((_) {
    stop();
    if (!ready.isCompleted) {
      ready.completeError(
        DioException.requestCancelled(
          requestOptions: request,
          reason: 'Public catalog request cancelled',
        ),
      );
    }
  });
  Future<void> run(int index, MetadataFetch fetch) async {
    try {
      final bytes = BytesBuilder(copy: false);
      final result = await (() async {
        final response = await fetch(aborts[index].future);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.stream.listen(null).cancel();
          throw DioException.badResponse(
            statusCode: response.statusCode,
            requestOptions: request,
            response: Response(
              requestOptions: request,
              statusCode: response.statusCode,
            ),
          );
        }
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const FormatException('Catalog response too large');
          }
          bytes.add(chunk);
        }
        final body = bytes.takeBytes();
        final valid = body.length < 128 * 1024
            ? _valid(request.uri, body)
            : await _validateInBackground(request.uri, body);
        if (!valid) throw const FormatException('Invalid catalog response');
        // Original compression lengths describe wire bytes, not this body.
        final headers = {...response.headers}
          ..remove('content-encoding')
          ..remove('content-length');
        return ResponseBody(
          Stream.value(body),
          response.statusCode,
          headers: headers,
        );
      })().timeout(const Duration(seconds: 15));
      if (!ready.isCompleted) ready.complete(result);
    } catch (error, stack) {
      if (++failed == 2 && !ready.isCompleted) {
        ready.completeError(error, stack);
      }
    } finally {
      if (!aborts[index].isCompleted) aborts[index].complete();
    }
  }

  unawaited(run(0, origin));
  unawaited(run(1, relay));
  try {
    return await ready.future;
  } finally {
    stop();
  }
}

// Keep this closure's context free of native clients and request completers.
Future<bool> _validateInBackground(Uri uri, Uint8List bytes) =>
    Isolate.run(() => _valid(uri, bytes));

bool _valid(Uri uri, Uint8List bytes) {
  if (bytes.isEmpty) return false;
  if (uri.path.endsWith('.torrent')) {
    final data = bencode.decode(bytes);
    final info = data is Map ? data['info'] : null;
    return info is Map &&
        info['piece length'] is int &&
        (info['piece length'] as int) > 0 &&
        info['pieces'] is List &&
        (info['pieces'] as List).isNotEmpty &&
        (info['pieces'] as List).length % 20 == 0;
  }
  final text = utf8.decode(bytes);
  if (uri.host == 'mikanani.me') {
    if (uri.path.startsWith('/RSS/')) {
      final root = XmlDocument.parse(text).rootElement;
      return root.name.local == 'rss' && root.getElement('channel') != null;
    }
    return text.contains('<title>Mikan Project') &&
        (text.contains('bangumi-title') ||
            text.contains('an-info') ||
            text.contains('js-search-result') ||
            text.contains('name="searchstr"'));
  }
  final data = jsonDecode(text);
  return data is Map &&
      data['list'] is List &&
      (!data.containsKey('code') || data['code'].toString() == '1');
}
