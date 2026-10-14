import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html;
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/network/mikan_http_adapter.dart';
import 'package:xml/xml.dart';

import 'rss_models.dart';
import 'rss_release_title_parser.dart';

export 'rss_models.dart';
export 'rss_release_title_parser.dart';

typedef MikanRssTransport =
    Future<String> Function(Uri uri, CancelToken? cancelToken);

const _maxResponseBytes = 8 * 1024 * 1024;
const _isolateParsingThreshold = 128 * 1024;

final mikanBaseUri = Uri.parse('https://mikanani.me/');

bool isMikanUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host.toLowerCase() == 'mikanani.me' &&
    uri.userInfo.isEmpty &&
    (!uri.hasPort || uri.port == 443);

bool isMikanFeedUri(Uri uri) =>
    isMikanUri(uri) &&
    const {
      '/rss/bangumi',
      '/rss/classic',
      '/rss/search',
      '/rss/mybangumi',
    }.contains(uri.path.toLowerCase());

bool isMikanTorrentUri(Uri uri) =>
    isMikanUri(uri) &&
    RegExp(r'^/Download/\d{8}/[a-fA-F0-9]{40}\.torrent$').hasMatch(uri.path);

bool isMikanEpisodeUri(Uri uri) =>
    isMikanUri(uri) &&
    RegExp(r'^/Home/Episode/[a-fA-F0-9]{40}/?$').hasMatch(uri.path);

Uri mikanGroupFeedUri(int mikanId, int groupId) => mikanBaseUri
    .resolve('/RSS/Bangumi')
    .replace(
      queryParameters: {'bangumiId': '$mikanId', 'subgroupid': '$groupId'},
    );

int? mikanFeedId(Uri uri, String name) {
  final values = uri.queryParametersAll.entries
      .where((entry) => entry.key.toLowerCase() == name.toLowerCase())
      .expand((entry) => entry.value)
      .toList();
  if (values.length != 1) return null;
  final id = int.tryParse(values.single);
  return id != null && id > 0 ? id : null;
}

class MikanRssClient {
  MikanRssClient({
    Dio? dio,
    MikanRssTransport? transport,
    NetworkConfig Function()? networkConfig,
    Dio Function(NetworkConfig)? createDio,
    this.requestTimeout = const Duration(seconds: 20),
    DateTime Function()? clock,
  }) : _dio = dio,
       _transport = transport,
       _networkConfig = networkConfig ?? NetworkConfig.fromSettings,
       _createDio = createDio ?? _createMikanDio,
       _clock = clock ?? DateTime.now;
  final Dio? _dio;
  Dio? _ownedDio;
  (Uri?, bool)? _ownedRoute;
  final NetworkConfig Function() _networkConfig;
  final Dio Function(NetworkConfig) _createDio;
  final MikanRssTransport? _transport;
  final DateTime Function() _clock;
  final Duration requestTimeout;
  final Map<int, ({MikanShow show, DateTime expires})> _shows = {};

  /// Shows that matched no Mikan entry, until when to skip looking again.
  final Map<int, DateTime> _unmatched = {};

  Future<List<MikanShow>> searchShows(
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    final query = String.fromCharCodes(keyword.trim().runes.take(19));
    if (query.isEmpty) return const [];
    final uri = mikanBaseUri
        .resolve('/Home/Search')
        .replace(queryParameters: {'searchstr': query});
    final source = await _request(uri, cancelToken);
    final shows = source.length >= _isolateParsingThreshold
        ? await compute(_parseMikanSearchWorker, source)
        : parseMikanSearch(source);
    _checkCancelled(cancelToken);
    return shows;
  }

  Future<MikanShow> getShow(
    int id, {
    CancelToken? cancelToken,
    bool forceRefresh = false,
  }) async {
    _checkCancelled(cancelToken);
    if (id <= 0) throw const RssException('蜜柑条目 ID 无效');
    _shows.removeWhere((_, value) => !_clock().isBefore(value.expires));
    final cached = _shows.remove(id);
    if (!forceRefresh && cached != null) {
      _shows[id] = cached;
      return cached.show;
    }
    final source = await _request(
      mikanBaseUri.resolve('/Home/Bangumi/$id'),
      cancelToken,
    );
    final show = source.length >= _isolateParsingThreshold
        ? await compute(_parseMikanShowWorker, (source, id))
        : parseMikanShow(source, id);
    _checkCancelled(cancelToken);
    _shows[id] = (
      show: show,
      expires: _clock().add(const Duration(minutes: 5)),
    );
    while (_shows.length > 64) {
      _shows.remove(_shows.keys.first);
    }
    return show;
  }

  Future<MikanShow?> resolveSubject(
    BangumiItem subject, {
    CancelToken? cancelToken,
  }) async {
    _checkCancelled(cancelToken);
    final bangumiId = subject.id;
    final names = [subject.nameCn, ...subject.alias, subject.name]
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .take(3)
        .toList();
    for (final cached in _shows.values) {
      if (cached.show.bangumiId == bangumiId &&
          _clock().isBefore(cached.expires)) {
        return cached.show;
      }
    }
    final miss = _unmatched[bangumiId];
    if (miss != null && _clock().isBefore(miss)) return null;
    final inspected = <int>{};
    for (final name in names) {
      _checkCancelled(cancelToken);
      // Each candidate costs a page request; the right one ranks near the top.
      final candidates = (await searchShows(
        name,
        cancelToken: cancelToken,
      )).take(12).toList();
      // Verify identities from official Bangumi links, never title similarity.
      for (var start = 0; start < candidates.length; start += 3) {
        final chunk = candidates
            .skip(start)
            .take(3)
            .where((show) => inspected.add(show.id));
        final details = await Future.wait(
          chunk.map((candidate) async {
            try {
              return await getShow(candidate.id, cancelToken: cancelToken);
            } catch (_) {
              _checkCancelled(cancelToken);
              return null;
            }
          }),
        );
        _checkCancelled(cancelToken);
        for (final show in details) {
          if (show?.bangumiId == bangumiId) return show;
        }
      }
    }
    _unmatched.removeWhere((_, until) => !_clock().isBefore(until));
    _unmatched[bangumiId] = _clock().add(const Duration(minutes: 30));
    return null;
  }

  /// [resolveShow] also reads the show page to report its Bangumi id; a
  /// routine refresh of a verified subscription skips it.
  Future<RssFeedPreview> previewFeed(
    Uri uri, {
    CancelToken? cancelToken,
    bool resolveShow = true,
  }) async {
    if (!isMikanFeedUri(uri)) throw const RssException('仅支持蜜柑官网的 HTTPS RSS 地址');
    final mikanId = uri.path.toLowerCase() == '/rss/bangumi'
        ? mikanFeedId(uri, 'bangumiId')
        : null;
    final show = mikanId == null || !resolveShow
        ? null
        : await getShow(mikanId, cancelToken: cancelToken);
    final source = await _request(uri, cancelToken);
    final parsed = source.length >= _isolateParsingThreshold
        ? await compute(_parseMikanFeedWorker, (source, uri))
        : parseMikanFeed(source, uri);
    _checkCancelled(cancelToken);
    return RssFeedPreview(
      uri: uri,
      title: parsed.title,
      releases: parsed.releases,
      mikanId: mikanId,
      subtitleGroupId: parsed.subtitleGroupId,
      bangumiId: show?.bangumiId,
    );
  }

  Future<String> _request(Uri uri, CancelToken? callerToken) async {
    if (!isMikanUri(uri)) throw const RssException('蜜柑请求地址无效');
    _checkCancelled(callerToken);
    final token = CancelToken();
    final cancellation = callerToken?.whenCancel.asStream().listen(
      (error) => token.cancel(error),
    );
    final timer = Timer(requestTimeout, () => token.cancel('蜜柑请求超时'));
    try {
      final Future<String> request;
      if (_transport != null) {
        request = _transport(uri, token);
      } else {
        // An imported personal RSS URL can contain a secret token. Use a
        // dedicated client with request logging disabled instead of apiDio.
        final dio = _dio ?? _clientFor(uri);
        request = dio
            .get<String>(
              uri.toString(),
              cancelToken: token,
              options: Options(
                responseType: ResponseType.plain,
                followRedirects: false,
              ),
              onReceiveProgress: (received, _) {
                if (received > _maxResponseBytes && !token.isCancelled) {
                  token.cancel('蜜柑返回内容过大');
                }
              },
            )
            .then((response) => response.data ?? '');
      }
      final body = await Future.any([
        request,
        token.whenCancel.then<String>((error) => throw error),
      ]);
      _checkCancelled(callerToken);
      if (body.length > _maxResponseBytes) throw const RssException('蜜柑返回内容过大');
      return body;
    } catch (_) {
      _checkCancelled(callerToken);
      // Never expose request URI, XML contents or a token-bearing DioException.
      throw const RssException('蜜柑连接失败，请稍后重试');
    } finally {
      timer.cancel();
      await cancellation?.cancel();
    }
  }

  Dio _clientFor(Uri uri) {
    final config = _networkConfig().copyWith(enableLog: false);
    final route = (config.proxyForUri(uri), config.allowBadCertificates);
    if (_ownedDio == null || _ownedRoute != route) {
      // This client is deliberately outside DioFactory's shared clients to
      // protect personal RSS tokens. Refresh its connection pool too when a
      // manual/system proxy changes, without cancelling in-flight requests.
      final previous = _ownedDio;
      _ownedDio = _createDio(config);
      _ownedRoute = route;
      previous?.close();
    }
    return _ownedDio!;
  }

  void dispose() => _ownedDio?.close(force: true);
}

Dio _createMikanDio(NetworkConfig config) {
  final dio = DioFactory.createForConfig(config);
  dio.httpClientAdapter = MikanHttpAdapter(
    fallback: dio.httpClientAdapter,
    proxyForUri: config.proxyForUri,
  );
  return dio;
}

List<MikanShow> parseMikanSearch(String source) {
  final document = html.parse(source);
  final shows = <int, MikanShow>{};
  for (final anchor in document.querySelectorAll('a[href]')) {
    final uri = mikanBaseUri.resolve(anchor.attributes['href']!);
    final match = RegExp(r'^/Home/Bangumi/(\d+)/?$').firstMatch(uri.path);
    if (!isMikanUri(uri) || match == null) continue;
    final id = int.parse(match[1]!);
    final title = (anchor.querySelector('.an-info')?.text ?? anchor.text)
        .trim();
    if (id <= 0 || title.isEmpty) continue;
    shows.putIfAbsent(
      id,
      () => MikanShow(id: id, title: title, detailUri: uri),
    );
    if (shows.length >= 20) break;
  }
  return List.unmodifiable(shows.values);
}

MikanShow parseMikanShow(String source, int id) {
  final document = html.parse(source);
  final title = document.querySelector('.bangumi-title')?.text.trim() ?? '';
  if (title.isEmpty) throw const RssException('蜜柑条目页面无效');
  final bangumiIds = <int>{};
  for (final anchor in document.querySelectorAll('.bangumi-info a[href]')) {
    final uri = Uri.tryParse(anchor.attributes['href']!);
    final match = uri == null
        ? null
        : RegExp(r'^/subject/(\d+)/?$').firstMatch(uri.path);
    if (uri != null &&
        const {'https', 'http'}.contains(uri.scheme) &&
        uri.userInfo.isEmpty &&
        const {'bgm.tv', 'bangumi.tv', 'chii.in'}.contains(uri.host) &&
        match != null) {
      bangumiIds.add(int.parse(match[1]!));
    }
  }
  final names = <int, String>{};
  for (final label in document.querySelectorAll('.subgroup-name')) {
    final group = int.tryParse(
      (label.attributes['data-anchor'] ?? '').replaceFirst('#', ''),
    );
    if (group != null && label.text.trim().isNotEmpty) {
      names[group] = label.text.trim();
    }
  }
  final groups = <int, MikanSubtitleGroup>{};
  for (final anchor in document.querySelectorAll('a[href]')) {
    final uri = mikanBaseUri.resolve(anchor.attributes['href']!);
    if (!isMikanFeedUri(uri) ||
        uri.path.toLowerCase() != '/rss/bangumi' ||
        mikanFeedId(uri, 'bangumiId') != id) {
      continue;
    }
    final groupId = mikanFeedId(uri, 'subgroupid');
    if (groupId == null || !names.containsKey(groupId)) continue;
    groups[groupId] = MikanSubtitleGroup(
      id: groupId,
      name: names[groupId]!,
      feedUri: mikanGroupFeedUri(id, groupId),
    );
  }
  return MikanShow(
    id: id,
    title: title,
    detailUri: mikanBaseUri.resolve('/Home/Bangumi/$id'),
    bangumiId: bangumiIds.length == 1 ? bangumiIds.single : null,
    groups: List.unmodifiable(groups.values),
  );
}

RssFeedPreview parseMikanFeed(String source, Uri uri) {
  if (!isMikanFeedUri(uri) ||
      RegExp(r'<!DOCTYPE|<!ENTITY', caseSensitive: false).hasMatch(source)) {
    throw const RssException('RSS 格式或地址无效');
  }
  final XmlDocument document;
  try {
    document = XmlDocument.parse(source);
  } catch (_) {
    throw const RssException('蜜柑未返回有效 RSS');
  }
  final root = document.rootElement;
  final channel = root.getElement('channel');
  if (root.name.local != 'rss' || channel == null) {
    throw const RssException('蜜柑未返回有效 RSS');
  }
  final releases = <String, RssRelease>{};
  for (final item in channel.findElements('item').take(1000)) {
    final title = item.getElement('title')?.innerText.trim() ?? '';
    final enclosure = item.getElement('enclosure');
    final download = Uri.tryParse(enclosure?.getAttribute('url') ?? '');
    final torrent = download != null && isMikanTorrentUri(download)
        ? download
        : null;
    final magnetText = item.descendants
        .whereType<XmlElement>()
        .where((node) => node.name.local.toLowerCase() == 'magnet')
        .map((node) => node.innerText.trim())
        .firstOrNull;
    final magnetCandidate = Uri.tryParse(
      magnetText ?? (download?.scheme == 'magnet' ? download.toString() : ''),
    );
    final magnet = validRssMagnet(magnetCandidate) ? magnetCandidate : null;
    final linkText = item.getElement('link')?.innerText.trim() ?? '';
    final detail = mikanBaseUri.resolve(linkText);
    if (title.isEmpty ||
        (torrent == null && magnet == null) ||
        !isMikanEpisodeUri(detail)) {
      continue;
    }
    final key = detail.pathSegments.lastWhere((part) => part.isNotEmpty);
    final metadata = parseRssReleaseTitle(title);
    final timeText = item.descendants
        .whereType<XmlElement>()
        .where((node) => node.name.local.toLowerCase() == 'pubdate')
        .map((node) => node.innerText.trim())
        .firstOrNull;
    final lengthText =
        item.descendants
            .whereType<XmlElement>()
            .where((node) => node.name.local.toLowerCase() == 'contentlength')
            .map((node) => node.innerText.trim())
            .firstOrNull ??
        enclosure?.getAttribute('length');
    releases.putIfAbsent(
      key,
      () => RssRelease(
        key: key,
        title: title,
        detailUri: detail,
        torrentUri: torrent,
        magnetUri: magnet,
        episodeNumber: metadata.episodeNumber,
        episodeNumbers: metadata.episodeNumbers,
        isBatch: metadata.isBatch,
        isSpecial: metadata.isSpecial,
        specialKey: metadata.specialKey,
        quality: metadata.quality,
        group: metadata.group,
        publishedAt: _rssTime(timeText),
        sizeBytes: int.tryParse(lengthText ?? ''),
      ),
    );
  }
  return RssFeedPreview(
    uri: uri,
    title: channel.getElement('title')?.innerText.trim() ?? '蜜柑 RSS',
    releases: List.unmodifiable(releases.values),
    mikanId: mikanFeedId(uri, 'bangumiId'),
    subtitleGroupId: mikanFeedId(uri, 'subgroupid'),
  );
}

bool validRssMagnet(Uri? uri) =>
    uri != null &&
    uri.scheme == 'magnet' &&
    uri.queryParametersAll['xt']?.any(
          (value) => RegExp(
            r'^urn:btih:(?:[a-fA-F0-9]{40}|[A-Z2-7a-z]{32})$',
          ).hasMatch(value),
        ) ==
        true;

DateTime? _rssTime(String? value) {
  if (value == null || value.isEmpty) return null;
  try {
    if (RegExp(r'^\d{4}-\d\d-\d\dT').hasMatch(value)) {
      final zoned = RegExp(
        r'(?:Z|[+-]\d\d:?\d\d)$',
        caseSensitive: false,
      ).hasMatch(value);
      return DateTime.parse(zoned ? value : '$value+08:00').toUtc();
    }
    return HttpDate.parse(value).toUtc();
  } catch (_) {
    return null;
  }
}

void _checkCancelled(CancelToken? token) {
  if (token?.isCancelled ?? false) throw token!.cancelError!;
}

// Top-level workers do not capture clients, cancel tokens, or app state.
List<MikanShow> _parseMikanSearchWorker(String source) =>
    parseMikanSearch(source);
MikanShow _parseMikanShowWorker((String, int) args) =>
    parseMikanShow(args.$1, args.$2);
RssFeedPreview _parseMikanFeedWorker((String, Uri) args) =>
    parseMikanFeed(args.$1, args.$2);
