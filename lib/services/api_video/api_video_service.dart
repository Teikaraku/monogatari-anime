import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/api_video/api_video_models.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'episode_identity.dart';
import 'api_video_url_policy.dart';

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
    this.providerPreferenceWait = const Duration(milliseconds: 1200),
    this.aliasHedgeDelay = const Duration(milliseconds: 250),
    this.maxCachedProviders = 96,
    this.maxResponseBytes = 8 * 1024 * 1024,
    DateTime Function()? clock,
  }) : assert(maxCachedProviders > 0),
       assert(!providerPreferenceWait.isNegative),
       assert(!aliasHedgeDelay.isNegative),
       _dio = dio,
       _transport = transport,
       _clock = clock ?? DateTime.now;

  final Dio? _dio;
  final ApiVideoTransport? _transport;
  final DateTime Function() _clock;
  final Duration cacheTtl;
  final Duration providerTimeout;

  /// Prefer the configured order briefly, then use an already-ready backup.
  final Duration providerPreferenceWait;
  final Duration aliasHedgeDelay;
  final int maxCachedProviders;
  final int maxResponseBytes;
  final Map<String, _CachedTitles> _cache = {};
  final Map<String, _ProviderFlight> _inFlight = {};
  final Map<ApiVideoProvider, (DateTime, ApiVideoFailure)> _providerFailures =
      {};
  int _cacheRevision = 0;

  void clearCache() {
    _cacheRevision++;
    _cache.clear();
    _providerFailures.clear();
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
    final failures = <ApiVideoFailure?>[];
    await for (final outcome in _readyOutcomes(preparation)) {
      _checkCancelled(cancelToken);
      final titles = outcome.titles;
      failures.add(outcome.failure);
      _checkCancelled(cancelToken);
      if (titles.isNotEmpty) return titles.first.catalog;
    }
    throw ApiVideoUnavailableException.fromFailures(failures);
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
    await for (final outcome in _readyOutcomes(
      preparation,
      preferOrder: false,
    )) {
      _checkCancelled(cancelToken);
      final titles = outcome.titles;
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
  /// candidates prefer the configured order without waiting on a stalled API.
  Stream<ApiVideoCandidate> candidatesForEpisode(
    BangumiItem subject,
    ApiVideoEpisode episode, {
    CancelToken? cancelToken,
  }) => _preparedStream<ApiVideoCandidate>(subject, cancelToken, (
    preparation,
  ) async* {
    final emitted = <String>{};
    final failures = <ApiVideoFailure?>[];
    await for (final outcome in _readyOutcomes(preparation)) {
      _checkCancelled(cancelToken);
      final titles = outcome.titles;
      failures.add(outcome.failure);
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
    if (emitted.isEmpty) {
      throw ApiVideoUnavailableException.fromFailures(failures);
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
    final loads = <Future<_ProviderOutcome>>[];
    for (final provider in apiVideoProviderPriority) {
      if (callerToken?.isCancelled ?? false) {
        scope.cancel(callerToken!.cancelError);
      }
      loads.add(_loadProvider(query, provider, scope));
    }
    final preferredFlight =
        _inFlight[query.providerKey(apiVideoProviderPriority.first)];
    final alreadyWaited = preferredFlight?.elapsed.elapsed ?? Duration.zero;
    final remainingWait = providerPreferenceWait - alreadyWaited;
    return _MetadataPreparation(
      scope,
      loads,
      cancellation,
      preferenceWait: remainingWait.isNegative ? Duration.zero : remainingWait,
    );
  }

  Stream<_ProviderOutcome> _readyOutcomes(
    _MetadataPreparation preparation, {
    bool preferOrder = true,
  }) async* {
    final remaining = List.generate(preparation.loads.length, (index) => index);
    while (remaining.isNotEmpty) {
      final wait = preferOrder
          ? preparation.preferenceWait - preparation.elapsed.elapsed
          : Duration.zero;
      final preferred = remaining.first;
      final index = preparation.outcomes.containsKey(preferred)
          ? preferred
          : wait > Duration.zero
          ? null
          : remaining.where(preparation.outcomes.containsKey).firstOrNull;
      if (index != null) {
        remaining.remove(index);
        final error = preparation.errors[index];
        if (error != null) Error.throwWithStackTrace(error.$1, error.$2);
        yield preparation.outcomes[index]!;
        continue;
      }
      final changed = preparation.changed;
      if (wait > Duration.zero) {
        await changed.timeout(wait, onTimeout: () {});
      } else {
        await changed;
      }
    }
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

  Future<_ProviderOutcome> _loadProvider(
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
      return cached.outcome;
    }
    final health = _providerFailures[provider];
    if (health != null && _clock().isBefore(health.$1)) {
      return _ProviderOutcome(const [], health.$2);
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

  Future<_ProviderOutcome> _joinFlight(
    _ProviderFlight flight,
    CancelToken? callerToken,
  ) {
    final result = Completer<_ProviderOutcome>();
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
    ApiVideoFailure? failure;
    try {
      result = await Future.any([
        _searchProvider(provider, query.names, query.year, flight.token),
        flight.token.whenCancel.then<List<_ProviderTitle>>(
          (error) => throw error,
        ),
      ]);
    } catch (error) {
      // A challenge page, unavailable API, invalid response or source timeout
      // must allow the next provider to run, never open a captcha/source sheet.
      failure = _failureFor(error);
    } finally {
      timer.cancel();
    }
    if (!flight.abandoned && flight.revision == _cacheRevision) {
      if (failure == ApiVideoFailure.network ||
          failure == ApiVideoFailure.timeout ||
          failure == ApiVideoFailure.blocked) {
        _providerFailures[provider] = (
          _clock().add(const Duration(seconds: 15)),
          failure!,
        );
      } else if (failure == null) {
        _providerFailures.remove(provider);
      }
      _pruneCache();
      _cache.remove(flight.key);
      _cache[flight.key] = _CachedTitles(
        _ProviderOutcome(result, failure),
        _clock().add(
          failure != null
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
    flight.result.complete(_ProviderOutcome(result, failure));
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
    final keywords = _searchKeywords(names).toList();
    if (keywords.length == 1) {
      return _searchKeyword(provider, keywords.single, expected, year, token);
    }
    final scope = CancelToken();
    final cancellation = token.whenCancel.asStream().listen(scope.cancel);
    final result = Completer<List<_ProviderTitle>>();
    var next = 0;
    var active = 0;
    Object? failure;
    Timer? hedge;
    void launch() {
      if (result.isCompleted || scope.isCancelled || next >= keywords.length) {
        return;
      }
      final keyword = keywords[next++];
      active++;
      unawaited(() async {
        try {
          final titles = await _searchKeyword(
            provider,
            keyword,
            expected,
            year,
            scope,
          );
          if (titles.isNotEmpty && !result.isCompleted) result.complete(titles);
        } catch (error) {
          failure ??= error;
        } finally {
          active--;
          if (!result.isCompleted) {
            if (next < keywords.length) {
              launch();
            } else if (active == 0) {
              if (failure != null) {
                result.completeError(failure!);
              } else {
                result.complete(const []);
              }
            }
          }
        }
      }());
    }

    // Keep at most two aliases in flight per provider. A slow or empty first
    // spelling must not hold up a valid translated title for several seconds.
    launch();
    hedge = Timer(aliasHedgeDelay, () {
      if (active < 2) launch();
    });
    try {
      final titles = await Future.any([
        result.future,
        token.whenCancel.then<List<_ProviderTitle>>((error) => throw error),
      ]);
      _checkCancelled(token);
      return titles;
    } finally {
      hedge.cancel();
      scope.cancel('已完成资源站搜索');
      await cancellation.cancel();
    }
  }

  Future<List<_ProviderTitle>> _searchKeyword(
    ApiVideoProvider provider,
    String keyword,
    Set<String> expected,
    int? year,
    CancelToken token,
  ) async {
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
      if ((await _matchingTitles(provider, rows, expected, year)).isNotEmpty) {
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
    final parsed = await _matchingTitles(provider, rows, expected, year);
    _checkCancelled(token);
    return parsed;
  }

  Future<List<_ProviderTitle>> _matchingTitles(
    ApiVideoProvider provider,
    List<Map<String, dynamic>> rows,
    Set<String> expected,
    int? year,
  ) async {
    final matched = rows.where((row) => _matches(row, expected)).toList();
    if (year != null) {
      // A single old remake is still a mismatch. Missing years cannot prove
      // that a namesake belongs to the requested Bangumi subject either.
      matched.removeWhere((row) => _text(row['vod_year']) != '$year');
    }
    final weight = matched.fold<int>(
      0,
      (size, row) => size + _text(row['vod_play_url']).length,
    );
    return weight >= 128 * 1024
        ? await compute(_parseProviderTitles, (provider, matched))
        : _parseProviderTitles((provider, matched));
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
      final child = CancelToken();
      final cancellation = token?.whenCancel.asStream().listen(
        (error) => child.cancel(error),
      );
      try {
        final response = await (_dio ?? DioFactory.apiDio).get<ResponseBody>(
          uri.toString(),
          cancelToken: child,
          options: Options(
            responseType: ResponseType.stream,
            connectTimeout: const Duration(seconds: 6),
            sendTimeout: const Duration(seconds: 6),
            receiveTimeout: const Duration(seconds: 8),
            headers: const {'accept': 'application/json'},
          ),
        );
        final declared = int.tryParse(
          response.headers.value('content-length') ?? '',
        );
        final body = BytesBuilder(copy: false);
        if (declared != null && declared > maxResponseBytes) {
          child.cancel('Response too large');
          throw const FormatException('资源站响应过大');
        }
        await for (final block in response.data!.stream) {
          _checkCancelled(token);
          if (body.length + block.length > maxResponseBytes) {
            child.cancel('Response too large');
            throw const FormatException('资源站响应过大');
          }
          body.add(block);
        }
        final bytes = body.takeBytes();
        raw = bytes.length >= 128 * 1024
            ? await compute(_decodeProviderBytes, bytes)
            : _decodeProviderBytes(bytes);
      } finally {
        await cancellation?.cancel();
      }
    }
    _checkCancelled(token);
    if (raw is String &&
        (raw.length > maxResponseBytes ||
            utf8.encode(raw).length > maxResponseBytes)) {
      throw const FormatException('资源站响应过大');
    }
    final document = raw is String
        ? raw.length >= 128 * 1024
              ? await compute(_decodeProviderText, raw)
              : _decodeProviderText(raw)
        : raw;
    if (document is! Map) throw const FormatException('资源站未返回 JSON 对象');
    final result = Map<String, dynamic>.from(document);
    if (result['list'] is! List) throw const FormatException('资源站响应缺少列表');
    if ((result['list'] as List).length > 5000) {
      throw const FormatException('资源站条目过多');
    }
    return result;
  }
}

Object? _decodeProviderBytes(Uint8List bytes) =>
    _decodeProviderText(utf8.decode(bytes));
Object? _decodeProviderText(String text) {
  if (text.trimLeft().startsWith('<')) {
    throw const ApiVideoUnavailableException(
      '片源返回了验证页',
      ApiVideoFailure.blocked,
    );
  }
  return jsonDecode(text);
}

List<_ProviderTitle> _parseProviderTitles(
  (ApiVideoProvider, List<Map<String, dynamic>>) args,
) => args.$2
    .map((row) => _parseTitle(args.$1, row))
    .whereType<_ProviderTitle>()
    .toList();

ApiVideoFailure _failureFor(Object error) {
  if (error is ApiVideoUnavailableException && error.failure != null) {
    return error.failure!;
  }
  if (error is TimeoutException) return ApiVideoFailure.timeout;
  if (error is SocketException) return ApiVideoFailure.network;
  if (error is DioException) {
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.transformTimeout ||
      DioExceptionType.cancel => ApiVideoFailure.timeout,
      DioExceptionType.connectionError ||
      DioExceptionType.badCertificate => ApiVideoFailure.network,
      DioExceptionType.badResponse =>
        const {401, 403, 429, 503}.contains(error.response?.statusCode)
            ? ApiVideoFailure.blocked
            : ApiVideoFailure.network,
      DioExceptionType.unknown => ApiVideoFailure.network,
    };
  }
  return ApiVideoFailure.invalidResponse;
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
      if (uri == null || !isPublicVideoUri(uri)) {
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
  return ApiVideoEpisode(key: specialEpisodeKey(text), title: text);
}

bool _sameEpisode(ApiVideoEpisode desired, ApiVideoEpisode candidate) =>
    desired.number != null && candidate.number != null
    ? desired.number == candidate.number
    : canonicalEpisodeKey(desired.key) == canonicalEpisodeKey(candidate.key);

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
  const _CachedTitles(this.outcome, this.expires);
  final _ProviderOutcome outcome;
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
  final elapsed = Stopwatch()..start();
  final token = CancelToken();
  final result = Completer<_ProviderOutcome>();
  int consumers = 0;
  bool started = false;
  bool completed = false;
  bool abandoned = false;
}

class _MetadataPreparation {
  _MetadataPreparation(
    this.token,
    this.loads,
    this.cancellation, {
    required this.preferenceWait,
  }) {
    for (var index = 0; index < loads.length; index++) {
      final position = index;
      unawaited(
        loads[index].then<void>(
          (outcome) => _record(position, outcome),
          onError: (Object error, StackTrace stack) {
            errors[position] = (error, stack);
            _record(position, _ProviderOutcome(const [], _failureFor(error)));
          },
        ),
      );
    }
    settled = Future.wait(loads).then<void>((_) {});
    // Attach a handler immediately: lower-priority requests may be cancelled
    // before an ordered consumer reaches them. Each request owns a lease until
    // it settles, so returning the first catalog does not restart its warmup.
    unawaited(
      settled.then<void>((_) => dispose(), onError: (Object _) => dispose()),
    );
  }

  final CancelToken token;
  final List<Future<_ProviderOutcome>> loads;
  final Duration preferenceWait;
  final elapsed = Stopwatch()..start();
  final outcomes = <int, _ProviderOutcome>{};
  final errors = <int, (Object, StackTrace)>{};
  var _changed = Completer<void>();
  Future<void> get changed => _changed.future;
  final StreamSubscription<DioException>? cancellation;
  late final Future<void> settled;

  void _record(int index, _ProviderOutcome outcome) {
    outcomes[index] = outcome;
    final previous = _changed;
    _changed = Completer<void>();
    previous.complete();
  }

  void dispose() {
    unawaited(cancellation?.cancel());
    if (!token.isCancelled) token.cancel('目录准备结束');
  }
}

class _ProviderOutcome {
  const _ProviderOutcome(this.titles, this.failure);
  final List<_ProviderTitle> titles;
  final ApiVideoFailure? failure;
}
