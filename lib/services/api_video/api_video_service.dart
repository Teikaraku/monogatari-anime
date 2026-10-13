import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/api_video/api_video_models.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';

export 'api_video_models.dart';

typedef ApiVideoTransport =
    Future<Object?> Function(Uri uri, CancelToken? cancelToken);

/// Resolves official resource APIs without user rules or embedded WebViews.
/// Returned URLs are candidates: the player/downloader determines whether the
/// media actually decodes and advances the stream when a candidate fails.
class ApiVideoService {
  ApiVideoService({
    Dio? dio,
    ApiVideoTransport? transport,
    this.cacheTtl = const Duration(minutes: 5),
    this.providerTimeout = const Duration(seconds: 15),
    this.maxCachedProviders = 96,
    DateTime Function()? clock,
  }) : assert(maxCachedProviders > 0),
       _dio = dio,
       _transport = transport,
       _clock = clock ?? DateTime.now;

  final Dio? _dio;
  final ApiVideoTransport? _transport;
  final DateTime Function() _clock;
  final Duration cacheTtl;
  final Duration providerTimeout;
  final int maxCachedProviders;
  final Map<String, _CachedTitles> _cache = {};
  final Map<String, _ProviderFlight> _inFlight = {};
  int _cacheRevision = 0;

  void clearCache() {
    _cacheRevision++;
    _cache.clear();
    // Existing consumers may finish, but new requests must not join them or
    // accept their late cache writes after an explicit refresh.
    _inFlight.clear();
  }

  /// Prepares only collection API JSON, never playlists or media segments.
  /// Detail pages can await this in the background without delaying navigation.
  Future<void> prefetchCatalog(
    BangumiItem subject, {
    CancelToken? cancelToken,
  }) async {
    final preparation = _prepareMetadata(subject, cancelToken);
    await preparation.settled;
    _checkCancelled(cancelToken);
  }

  Future<ApiVideoCatalog> loadCatalog(
    BangumiItem subject, {
    CancelToken? cancelToken,
  }) async {
    final preparation = _prepareMetadata(subject, cancelToken);
    for (final load in preparation.loads) {
      _checkCancelled(cancelToken);
      final titles = await load;
      _checkCancelled(cancelToken);
      if (titles.isNotEmpty) return titles.first.catalog;
    }
    throw const ApiVideoUnavailableException();
  }

  /// Fills gaps after the first catalog is ready. Existing list positions are
  /// retained because the player/history use those positions while playing;
  /// only new source-independent episodes are sorted and appended.
  Stream<List<ApiVideoEpisode>> expandedEpisodes(
    BangumiItem subject,
    ApiVideoCatalog initial, {
    CancelToken? cancelToken,
  }) => _preparedStream<List<ApiVideoEpisode>>(subject, cancelToken, (
    preparation,
  ) async* {
    final episodes = [...initial.episodes];
    final keys = episodes.map((episode) => episode.key).toSet();
    for (final load in preparation.loads) {
      _checkCancelled(cancelToken);
      final titles = await load;
      final added = <ApiVideoEpisode>[];
      for (final title in titles) {
        for (final episode in title.catalog.episodes) {
          if (keys.add(episode.key)) added.add(episode);
        }
      }
      if (added.isEmpty) continue;
      added.sort(_compareEpisodes);
      episodes.addAll(added);
      _checkCancelled(cancelToken);
      yield List<ApiVideoEpisode>.unmodifiable(episodes);
    }
  });

  /// No work starts until listened to. Metadata is prepared concurrently, but
  /// candidates are always emitted in provider priority order.
  Stream<ApiVideoCandidate> candidatesForEpisode(
    BangumiItem subject,
    ApiVideoEpisode episode, {
    CancelToken? cancelToken,
  }) => _preparedStream<ApiVideoCandidate>(subject, cancelToken, (
    preparation,
  ) async* {
    final emitted = <String>{};
    for (final load in preparation.loads) {
      _checkCancelled(cancelToken);
      final titles = await load;
      for (final title in titles) {
        for (final candidate in title.candidates) {
          _checkCancelled(cancelToken);
          if (_sameEpisode(episode, candidate.episode) &&
              emitted.add(candidate.identity)) {
            yield candidate;
          }
        }
      }
    }
  });

  _MetadataPreparation _prepareMetadata(
    BangumiItem subject,
    CancelToken? callerToken,
  ) {
    _checkCancelled(callerToken);
    // Bangumi details are mutable. Matching and cache identity must use the
    // same names/year even if a detail refresh finishes during this request.
    final query = _SubjectQuery(subject);
    final scope = CancelToken();
    final cancellation = callerToken?.whenCancel.asStream().listen((error) {
      if (!scope.isCancelled) scope.cancel(error);
    });
    final loads = <Future<List<_ProviderTitle>>>[];
    for (final provider in apiVideoProviderPriority) {
      if (callerToken?.isCancelled ?? false) {
        scope.cancel(callerToken!.cancelError);
      }
      loads.add(_loadProvider(query, provider, scope));
    }
    return _MetadataPreparation(scope, loads, cancellation);
  }

  /// An async* finally alone cannot interrupt an await when its subscription
  /// is cancelled. Forward cancellation immediately to this stream's leases.
  Stream<T> _preparedStream<T>(
    BangumiItem subject,
    CancelToken? callerToken,
    Stream<T> Function(_MetadataPreparation) produce,
  ) {
    _MetadataPreparation? preparation;
    StreamSubscription<T>? subscription;
    var subscriptionCancelled = false;
    late final StreamController<T> controller;
    Stream<T> source() async* {
      final prepared = preparation = _prepareMetadata(subject, callerToken);
      try {
        yield* produce(prepared);
      } on DioException catch (error) {
        if (!subscriptionCancelled || !CancelToken.isCancel(error)) rethrow;
      } finally {
        prepared.dispose();
      }
    }

    controller = StreamController<T>(
      onListen: () {
        subscription = source().listen(
          controller.add,
          onError: (Object error, StackTrace stack) {
            if (!subscriptionCancelled) controller.addError(error, stack);
          },
          onDone: controller.close,
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        subscriptionCancelled = true;
        preparation?.dispose();
        try {
          await subscription?.cancel();
        } on DioException catch (error) {
          // Releasing an awaited lease can finish the generator's cancel
          // future with its cancellation error. Explicit unsubscribe succeeds.
          if (!CancelToken.isCancel(error)) rethrow;
        }
      },
    );
    return controller.stream;
  }

  Future<List<_ProviderTitle>> _loadProvider(
    _SubjectQuery query,
    ApiVideoProvider provider,
    CancelToken? callerToken,
  ) async {
    _checkCancelled(callerToken);
    _pruneCache();
    final key = query.providerKey(provider);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached; // Touch a cache hit for bounded LRU eviction.
      return cached.titles;
    }
    final flight = _inFlight.putIfAbsent(
      key,
      () => _ProviderFlight(key, _cacheRevision),
    );
    final result = _joinFlight(flight, callerToken);
    if (!flight.started) {
      flight.started = true;
      unawaited(_runProvider(flight, query, provider));
    }
    return result;
  }

  Future<List<_ProviderTitle>> _joinFlight(
    _ProviderFlight flight,
    CancelToken? callerToken,
  ) {
    final result = Completer<List<_ProviderTitle>>();
    var released = false;
    StreamSubscription<DioException>? cancellation;
    flight.consumers++;
    void release() {
      if (released) return;
      released = true;
      unawaited(cancellation?.cancel());
      flight.consumers--;
      if (flight.consumers == 0 && !flight.completed) {
        flight.abandoned = true;
        if (identical(_inFlight[flight.key], flight)) {
          _inFlight.remove(flight.key);
        }
        flight.token.cancel('目录请求已无人等待');
      }
    }

    cancellation = callerToken?.whenCancel.asStream().listen((error) {
      if (!result.isCompleted) result.completeError(error);
      release();
    });
    unawaited(
      flight.result.future.then((titles) {
        if (!result.isCompleted) result.complete(titles);
        release();
      }),
    );
    return result.future;
  }

  Future<void> _runProvider(
    _ProviderFlight flight,
    _SubjectQuery query,
    ApiVideoProvider provider,
  ) async {
    final timer = Timer(providerTimeout, () => flight.token.cancel('资源站请求超时'));
    var result = <_ProviderTitle>[];
    var failure = false;
    try {
      result = await Future.any([
        _searchProvider(provider, query.names, query.year, flight.token),
        flight.token.whenCancel.then<List<_ProviderTitle>>(
          (error) => throw error,
        ),
      ]);
    } catch (_) {
      // A challenge page, unavailable API, invalid response or source timeout
      // must allow the next provider to run, never open a captcha/source sheet.
      failure = true;
    } finally {
      timer.cancel();
    }
    if (!flight.abandoned && flight.revision == _cacheRevision) {
      _pruneCache();
      _cache.remove(flight.key);
      _cache[flight.key] = _CachedTitles(
        result,
        _clock().add(
          failure
              ? const Duration(seconds: 15)
              : result.isEmpty
              ? const Duration(seconds: 30)
              : cacheTtl,
        ),
      );
      while (_cache.length > maxCachedProviders) {
        _cache.remove(_cache.keys.first);
      }
    }
    flight.completed = true;
    if (identical(_inFlight[flight.key], flight)) _inFlight.remove(flight.key);
    flight.result.complete(result);
  }

  void _pruneCache() {
    final now = _clock();
    _cache.removeWhere((_, cached) => !now.isBefore(cached.expires));
  }

  Future<List<_ProviderTitle>> _searchProvider(
    ApiVideoProvider provider,
    List<String> names,
    int? year,
    CancelToken token,
  ) async {
    final expected = names
        .map(_normalizeTitle)
        .where((v) => v.isNotEmpty)
        .toSet();
    if (expected.isEmpty) return const [];
    for (final keyword in _searchKeywords(names)) {
      _checkCancelled(token);
      final document = await _providerRequest(provider, {
        'ac': 'detail',
        'wd': keyword,
        'pg': '1',
      }, token);
      final rows = _rows(document);
      final pages = int.tryParse(_text(document['pagecount'])) ?? 1;
      // Only matching search results are paged, never crawl a site's entire
      // library. Typical anime searches fit on one page.
      for (var page = 2; page <= pages && page <= 3; page++) {
        if (rows.any(
          (row) =>
              _matches(row, expected) && _parseTitle(provider, row) != null,
        )) {
          break;
        }
        rows.addAll(
          _rows(
            await _providerRequest(provider, {
              'ac': 'detail',
              'wd': keyword,
              'pg': '$page',
            }, token),
          ),
        );
      }
      final matched = rows.where((row) => _matches(row, expected)).toList();
      if (year != null && matched.length > 1) {
        final sameYear = matched
            .where((row) => _text(row['vod_year']) == '$year')
            .toList();
        if (sameYear.isNotEmpty) {
          matched.removeWhere((row) => !sameYear.contains(row));
        }
      }
      final parsed = matched
          .map((row) => _parseTitle(provider, row))
          .whereType<_ProviderTitle>()
          .toList();
      if (parsed.isNotEmpty) return parsed;
    }
    return const [];
  }

  Future<Map<String, dynamic>> _providerRequest(
    ApiVideoProvider provider,
    Map<String, String> query,
    CancelToken token,
  ) async {
    final endpoints = switch (provider) {
      ApiVideoProvider.zy1080 => ['https://api.yzzy-api.com/inc/apijson.php'],
      ApiVideoProvider.baofeng => ['https://bfzyapi.com/api.php/provide/vod/'],
      ApiVideoProvider.liangzi => [
        'https://cj.lziapi.com/api.php/provide/vod/',
      ],
    };
    Object? lastError;
    for (final endpoint in endpoints) {
      try {
        return await _request(
          Uri.parse(endpoint).replace(queryParameters: query),
          token,
        );
      } catch (error) {
        _checkCancelled(token);
        lastError = error;
      }
    }
    throw lastError ?? const ApiVideoUnavailableException();
  }

  Future<Map<String, dynamic>> _request(Uri uri, CancelToken? token) async {
    _checkCancelled(token);
    final injected = _transport;
    final Object? raw;
    if (injected != null) {
      raw = await injected(uri, token);
    } else {
      final response = await (_dio ?? DioFactory.apiDio).get<Object?>(
        uri.toString(),
        cancelToken: token,
        options: Options(
          responseType: ResponseType.plain,
          sendTimeout: const Duration(seconds: 6),
          receiveTimeout: const Duration(seconds: 8),
          headers: const {'accept': 'application/json'},
        ),
      );
      raw = response.data;
    }
    _checkCancelled(token);
    final document = raw is String ? jsonDecode(raw) : raw;
    if (document is! Map) throw const FormatException('资源站未返回 JSON 对象');
    final result = Map<String, dynamic>.from(document);
    if (result['list'] is! List) throw const FormatException('资源站响应缺少列表');
    return result;
  }
}

List<Map<String, dynamic>> _rows(Map<String, dynamic> document) =>
    (document['list'] as List)
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();

String _text(Object? value) => value?.toString().trim() ?? '';

void _checkCancelled(CancelToken? token) {
  if (token?.isCancelled ?? false) throw token!.cancelError!;
}

List<String> _subjectNames(BangumiItem subject) => [
  subject.nameCn,
  ...subject.alias,
  subject.name,
].map((name) => name.trim()).where((name) => name.isNotEmpty).toSet().toList();

Iterable<String> _searchKeywords(List<String> names) sync* {
  final queries = <String>{};
  for (final name in names) {
    queries.add(name.replaceAll(RegExp(r'\s+'), ''));
    // Searching the family title handles Chinese/Arabic season numbering;
    // final selection still requires a complete, season-sensitive name match.
    final family = name
        .replaceFirst(RegExp(r'\s*第?[一二三四五六七八九十百\d]+[季期].*$'), '')
        .trim();
    if (family.length >= 3 && family != name) queries.add(family);
  }
  yield* queries.take(6);
}

String _normalizeTitle(String raw) {
  var title = raw.toLowerCase().replaceAllMapped(
    RegExp(r'[Ａ-Ｚａ-ｚ０-９]'),
    (match) => String.fromCharCode(match[0]!.codeUnitAt(0) - 0xfee0),
  );
  title = title.replaceFirst(
    RegExp(
      r'[\s（(【\[]*(?:日语|日語|国语|國語|普通话|普通話|粤语|粵語|中文字幕|中字|高清|无删减|無刪減|完整版|动画版|動畫版)[\s）)】\]]*$',
    ),
    '',
  );
  title = title.replaceAllMapped(
    RegExp(r'第?([一二三四五六七八九十百\d]+)[季期]'),
    (match) => 's${_chineseNumber(match[1]!)}',
  );
  title = title.replaceAllMapped(
    RegExp(r'season\s*(\d+)'),
    (match) => 's${int.parse(match[1]!)}',
  );
  title = title.replaceAll(RegExp(r'[^a-z0-9\u3040-\u30ff\u3400-\u9fff]'), '');
  return title.replaceFirst(RegExp(r's1$'), '');
}

int _chineseNumber(String raw) {
  final arabic = int.tryParse(raw);
  if (arabic != null) return arabic;
  const digits = {
    '零': 0,
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  var total = 0;
  var current = 0;
  for (final char in raw.split('')) {
    if (char == '十' || char == '百') {
      total += (current == 0 ? 1 : current) * (char == '十' ? 10 : 100);
      current = 0;
    } else {
      current = digits[char] ?? 0;
    }
  }
  return total + current;
}

bool _matches(Map<String, dynamic> row, Set<String> expected) {
  final title = _text(row['vod_name']);
  if (!expected.contains(_normalizeTitle(title))) return false;
  // Do not confuse live-action remakes, commentary or shorts with an anime.
  final category = _text(row['type_name']);
  if (category.isNotEmpty &&
      !category.contains('动漫') &&
      !category.contains('动画') &&
      row['type_id_1']?.toString() != '4') {
    return false;
  }
  return !title.contains('解说') && !title.contains('解說');
}

_ProviderTitle? _parseTitle(
  ApiVideoProvider provider,
  Map<String, dynamic> row,
) {
  final id = _text(row['vod_id']);
  final title = _text(row['vod_name']);
  final groups = _text(row['vod_play_url']).split(r'$$$');
  final candidates = <ApiVideoCandidate>[];
  final episodes = <String, ApiVideoEpisode>{};
  for (final group in groups) {
    final entries = group
        .split('#')
        .where((entry) => entry.trim().isNotEmpty)
        .toList();
    for (final entry in entries) {
      final separator = entry.indexOf(r'$');
      if (separator < 0) continue;
      final label = entry.substring(0, separator).trim();
      final url = entry.substring(separator + 1).trim();
      final uri = Uri.tryParse(url);
      if (uri == null ||
          (uri.scheme != 'https' && uri.scheme != 'http') ||
          uri.host.isEmpty) {
        continue;
      }
      // Parser pages whose query embeds .m3u8 are intentionally rejected.
      final path = uri.path.toLowerCase();
      final isHls = path.endsWith('.m3u8');
      if (!isHls && !RegExp(r'\.(mp4|mkv|webm|mov|flv|ts)$').hasMatch(path)) {
        continue;
      }
      final episode = _parseEpisode(label, entries.length == 1);
      if (episode == null) continue;
      episodes.putIfAbsent(episode.key, () => episode);
      candidates.add(
        ApiVideoCandidate(
          provider: provider,
          id: id,
          title: title,
          episode: episode,
          url: url,
          format: isHls ? VideoSourceFormat.hls : VideoSourceFormat.auto,
          httpHeaders: {
            'Referer': switch (provider) {
              ApiVideoProvider.zy1080 => 'https://1080zyk4.com/',
              ApiVideoProvider.baofeng => 'https://bfzyapi.com/',
              ApiVideoProvider.liangzi => 'https://lzizy1.com/',
            },
            'User-Agent': 'Mozilla/5.0',
          },
        ),
      );
    }
  }
  if (episodes.isEmpty) return null;
  final sorted = episodes.values.toList()..sort(_compareEpisodes);
  return _ProviderTitle(
    ApiVideoCatalog(
      provider: provider,
      id: id,
      title: title,
      episodes: List.unmodifiable(sorted),
    ),
    candidates,
  );
}

ApiVideoEpisode? _parseEpisode(String label, bool singleton) {
  final text = label.trim();
  if (text.isEmpty) {
    return singleton
        ? const ApiVideoEpisode(key: '1', title: '正片', number: 1)
        : null;
  }
  final special = RegExp(
    r'(?:sp|ova|oad|特别|特別|特典|番外|预告|預告|pv|op|ed|总集|總集)',
    caseSensitive: false,
  ).hasMatch(text);
  if (!special) {
    final match = RegExp(
      r'^(?:第\s*|ep\s*|episode\s*)?(\d+(?:\.\d+)?)\s*(?:集|话|話|期)?(?:\s|$|[：:])',
      caseSensitive: false,
    ).firstMatch(text);
    final chinese = RegExp(r'^第([一二三四五六七八九十百]+)[集话話]').firstMatch(text);
    final number = match == null
        ? (chinese == null ? null : _chineseNumber(chinese[1]!).toDouble())
        : double.tryParse(match[1]!);
    if (number != null) {
      final key = number == number.truncateToDouble()
          ? '${number.toInt()}'
          : '$number';
      return ApiVideoEpisode(key: key, title: text, number: number);
    }
    if (singleton &&
        RegExp(
          r'^(?:正片|全集|电影|電影|hd|bd|蓝光|藍光|\d{3,4}p)',
          caseSensitive: false,
        ).hasMatch(text)) {
      return ApiVideoEpisode(key: '1', title: text, number: 1);
    }
  }
  // Never infer a numbered episode from its array position; extras may appear
  // first or differ between providers, causing the wrong episode to play.
  return ApiVideoEpisode(key: 'special:${_normalizeTitle(text)}', title: text);
}

bool _sameEpisode(ApiVideoEpisode desired, ApiVideoEpisode candidate) =>
    desired.number != null && candidate.number != null
    ? desired.number == candidate.number
    : desired.key == candidate.key;

int _compareEpisodes(ApiVideoEpisode a, ApiVideoEpisode b) {
  if (a.number != null && b.number != null) {
    return a.number!.compareTo(b.number!);
  }
  if (a.number != null) return -1;
  if (b.number != null) return 1;
  return a.key.compareTo(b.key);
}

class _ProviderTitle {
  const _ProviderTitle(this.catalog, this.candidates);
  final ApiVideoCatalog catalog;
  final List<ApiVideoCandidate> candidates;
}

class _CachedTitles {
  const _CachedTitles(this.titles, this.expires);
  final List<_ProviderTitle> titles;
  final DateTime expires;
}

class _SubjectQuery {
  _SubjectQuery(BangumiItem subject)
    : id = subject.id,
      names = _subjectNames(subject),
      year = int.tryParse(subject.airDate.split('-').first);

  final int id;
  final List<String> names;
  final int? year;

  String providerKey(ApiVideoProvider provider) {
    // Keyword search is ordered and capped. Reordering aliases can change the
    // actual queries, so it must not reuse another ordering's negative result.
    return jsonEncode([provider.id, id, names, year]);
  }
}

class _ProviderFlight {
  _ProviderFlight(this.key, this.revision);
  final String key;
  final int revision;
  final token = CancelToken();
  final result = Completer<List<_ProviderTitle>>();
  int consumers = 0;
  bool started = false;
  bool completed = false;
  bool abandoned = false;
}

class _MetadataPreparation {
  _MetadataPreparation(this.token, this.loads, this.cancellation) {
    settled = Future.wait(loads).then<void>((_) {});
    // Attach a handler immediately: lower-priority requests may be cancelled
    // before an ordered consumer reaches them. Each request owns a lease until
    // it settles, so returning the first catalog does not restart its warmup.
    unawaited(
      settled.then<void>((_) => dispose(), onError: (Object _) => dispose()),
    );
  }

  final CancelToken token;
  final List<Future<List<_ProviderTitle>>> loads;
  final StreamSubscription<DioException>? cancellation;
  late final Future<void> settled;

  void dispose() {
    unawaited(cancellation?.cancel());
    if (!token.isCancelled) token.cancel('目录准备结束');
  }
}
