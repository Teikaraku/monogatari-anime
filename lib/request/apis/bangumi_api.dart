import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/request/clients/bangumi_client.dart';
import 'package:kazumi/request/apis/main_episode_cache.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_relation.dart';
import 'package:kazumi/modules/bangumi/bangumi_subject_detail.dart';
import 'package:kazumi/modules/comments/comment_response.dart';
import 'package:kazumi/modules/characters/characters_response.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/modules/character/character_full_item.dart';
import 'package:kazumi/modules/staff/staff_response.dart';
import 'package:kazumi/modules/bangumi/bangumi_collection.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/collect/collect_type_mapper.dart';
import 'package:kazumi/modules/bangumi/bangumi_collection_type.dart';
import 'package:kazumi/modules/comments/comment_item.dart';
import 'package:kazumi/utils/search_parser.dart';
import 'package:kazumi/utils/async_rate_limiter.dart';

class BangumiSearchPage {
  const BangumiSearchPage({
    required this.items,
    required this.rawCount,
  });

  final List<BangumiItem> items;
  final int rawCount;
}

class BangumiApi {
  static final BangumiClient _client = BangumiClient.instance;
  static final AsyncRateLimiter _writeRateLimiter =
      AsyncRateLimiter(const Duration(milliseconds: 250));

  static Future<List<List<BangumiItem>>> getCalendar() async {
    List<List<BangumiItem>> bangumiCalendar = [];
    try {
      final jsonData = await _client.get(
        ApiEndpoints.bangumiAPINextDomain + ApiEndpoints.bangumiCalendar,
      );
      for (int i = 1; i <= 7; i++) {
        List<BangumiItem> bangumiList = [];
        final jsonList = jsonData['$i'];
        for (dynamic jsonItem in jsonList) {
          try {
            BangumiItem bangumiItem = BangumiItem.fromJson(jsonItem['subject']);
            bangumiList.add(bangumiItem);
          } catch (_) {}
        }
        bangumiCalendar.add(bangumiList);
      }
    } catch (e) {
      KazumiLogger().e('Resolve calendar failed', error: e);
    }
    return bangumiCalendar;
  }

  /// Browse uses the authoritative year/month index. The upstream search
  /// service currently returns empty results for otherwise valid date filters.
  static Future<List<List<BangumiItem>>> getSeasonCalendar(
    List<String> dateRange,
  ) async {
    final start = DateTime.parse(dateRange[0]);
    final end = DateTime.parse(dateRange[1]);
    final months = <DateTime>[];
    for (
      var month = DateTime(start.year, start.month);
      month.isBefore(end);
      month = DateTime(month.year, month.month + 1)
    ) {
      months.add(month);
    }
    final jobs = [
      for (final month in months)
        for (final cat in [1, 5]) (month, cat),
    ];
    final rows = <dynamic>[];
    // Bound concurrency across all months and pages.
    for (var i = 0; i < jobs.length; i += 3) {
      final batch = await Future.wait(
        jobs.skip(i).take(3).map((job) async {
          final result = <dynamic>[];
          var pages = 1;
          for (var page = 1; page <= pages; page++) {
            final response = await _client.get(
              '${ApiEndpoints.bangumiAPINextDomain}/p1/subjects',
              queryParameters: {
                'type': 2,
                'sort': 'date',
                'cat': job.$2,
                'year': job.$1.year,
                'month': job.$1.month,
                'page': page,
              },
            );
            if (response is! Map ||
                response['data'] is! List ||
                response['total'] is! num) {
              throw const FormatException('Invalid Bangumi season response');
            }
            pages = (response['total'] as num).toInt(); // total pages, not rows
            if (pages > 100) {
              throw const FormatException('Too many season pages');
            }
            result.addAll(response['data'] as List);
          }
          return result;
        }),
      );
      rows.addAll(batch.expand((items) => items));
    }
    final seen = <int>{};
    final days = List.generate(7, (_) => <BangumiItem>[]);
    for (final row in rows.whereType<Map<String, dynamic>>()) {
      if (row['nsfw'] == true) continue;
      final item = BangumiItem.fromJson(row);
      final date = DateTime.tryParse(item.airDate);
      if (date != null &&
          !date.isBefore(start) &&
          date.isBefore(end) &&
          seen.add(item.id)) {
        days[item.airWeekday - 1].add(item);
      }
    }
    return days;
  }

  static Future<List<dynamic>> _nextSubjectRows(int id, String path) async {
    final rows = <dynamic>[];
    var offset = 0;
    while (true) {
      final response = await _client.get(
        '${ApiEndpoints.bangumiAPINextDomain}/p1/subjects/$id/$path',
        queryParameters: {'limit': 100, 'offset': offset},
      );
      if (response is! Map ||
          response['data'] is! List ||
          response['total'] is! num) {
        throw const FormatException('Invalid Bangumi subject list');
      }
      final page = response['data'] as List;
      rows.addAll(page);
      offset += page.length;
      if (page.isEmpty || offset >= (response['total'] as num)) return rows;
      if (offset >= 10000) throw const FormatException('Too many Bangumi rows');
    }
  }

  /// Anime carrying the Bangumi public tag [metaTag] (an official 类型 such as
  /// 科幻 or 百合), most popular first.
  static Future<List<BangumiItem>> getBangumiListByMetaTag(String metaTag,
      {int limit = 24, int offset = 0}) async {
    List<BangumiItem> bangumiList = [];
    final params = <String, dynamic>{
      'keyword': '',
      'sort': 'heat',
      'filter': {
        'type': [2],
        'metaTags': [metaTag],
        'nsfw': false,
      },
    };
    try {
      final jsonData = await _client.post(
        ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPINextDomain + ApiEndpoints.bangumiSearchNext,
          [limit, offset],
        ),
        data: params,
      );
      final jsonList = jsonData['data'];
      for (dynamic jsonItem in jsonList) {
        if (jsonItem is Map<String, dynamic>) {
          bangumiList.add(BangumiItem.fromJson(jsonItem));
        }
      }
    } catch (e) {
      KazumiLogger().e('Network: resolve bangumi list failed', error: e);
    }
    return bangumiList;
  }
  static Future<List<BangumiItem>> getBangumiTrendsList(
      {int type = 2, int limit = 24, int offset = 0}) async {
    List<BangumiItem> bangumiList = [];
    var params = <String, dynamic>{
      'type': type,
      'limit': limit,
      'offset': offset,
    };
    try {
      final jsonData = await _client.get(
        ApiEndpoints.bangumiAPINextDomain + ApiEndpoints.bangumiTrendsNext,
        queryParameters: params,
      );
      final jsonList = jsonData['data'];
      for (dynamic jsonItem in jsonList) {
        if (jsonItem is Map<String, dynamic>) {
          bangumiList.add(BangumiItem.fromJson(jsonItem['subject']));
        }
      }
    } catch (e) {
      KazumiLogger().e('Network: resolve bangumi trends list failed', error: e);
    }
    return bangumiList;
  }

  static List<String> _buildNumberFilter<T extends num>(T? min, T? max) {
    return [
      if (min != null) '>=$min',
      if (max != null) '<=$max',
    ];
  }

  static Map<String, dynamic> buildBangumiSearchParams(
    String keyword, {
    List<String> tags = const [],
    String sort = 'heat',
    SearchDateRange? dateRange,
    SearchIntRange? rankRange,
    SearchDoubleRange? scoreRange,
    List<int> weekdays = const [],
  }) {
    final rankFilter = rankRange?.isValid == true
        ? _buildNumberFilter<int>(rankRange!.min, rankRange.max)
        : (sort == 'rank')
            ? [">0", "<=99999"]
            : [">=0", "<=99999"];

    // Official public tags match Bangumi's own classification; anything else
    // the user typed is matched against the free-form user tags.
    final metaTags = tags.where(bangumiOfficialMetaTags.contains).toList();
    final userTags =
        tags.where((tag) => !bangumiOfficialMetaTags.contains(tag)).toList();
    final filter = <String, dynamic>{
      "type": [2],
      if (metaTags.isNotEmpty) "meta_tags": metaTags,
      "tag": userTags,
      "rank": rankFilter,
      "nsfw": false,
    };

    if (dateRange?.isValid == true) {
      filter["air_date"] = [">=${dateRange!.start}", "<${dateRange.end}"];
    }
    if (scoreRange?.isValid == true) {
      filter["rating"] =
          _buildNumberFilter<double>(scoreRange!.min, scoreRange.max);
    }
    if (weekdays.isNotEmpty) {
      filter["air_weekday"] = weekdays.toSet().toList()..sort();
    }

    return <String, dynamic>{
      'keyword': keyword,
      'sort': sort,
      "filter": filter,
    };
  }

  /// p1 uses different field names. Date/weekday and exact decimal score
  /// bounds are applied locally: its current date index rejects valid ranges,
  /// and its score parser only accepts single-digit integers.
  static Map<String, dynamic> buildBangumiNextSearchParams(
    String keyword, {
    List<String> tags = const [],
    String sort = 'heat',
    SearchDateRange? dateRange,
    SearchIntRange? rankRange,
    SearchDoubleRange? scoreRange,
    List<int> weekdays = const [],
  }) {
    final params = buildBangumiSearchParams(
      keyword,
      tags: tags,
      sort: sort,
      dateRange: dateRange,
      rankRange: rankRange,
      scoreRange: scoreRange,
    );
    final filter = params['filter'] as Map<String, dynamic>;
    filter['tags'] = filter.remove('tag');
    if (filter.containsKey('meta_tags')) {
      filter['metaTags'] = filter.remove('meta_tags');
    }
    filter.remove('air_date');
    filter.remove('rating');
    if (scoreRange?.isValid == true) {
      final min = scoreRange!.min;
      final max = scoreRange.max;
      final bounds = <String>[
        if (min != null && min.floor() >= 0 && min.floor() <= 9)
          '>=${min.floor()}',
        if (max != null && max.ceil() >= 0 && max.ceil() <= 9)
          '<=${max.ceil()}',
      ];
      if (bounds.isNotEmpty) filter['rating'] = bounds;
    }
    return params;
  }

  static Future<BangumiSearchPage?> bangumiSearch(
    String keyword, {
    List<String> tags = const [],
    int limit = 20,
    int offset = 0,
    String sort = 'heat',
    SearchDateRange? dateRange,
    SearchIntRange? rankRange,
    SearchDoubleRange? scoreRange,
    List<int> weekdays = const [],
  }) async {
    List<BangumiItem> bangumiList = [];

    final params = buildBangumiNextSearchParams(
      keyword,
      tags: tags,
      sort: sort,
      dateRange: dateRange,
      rankRange: rankRange,
      scoreRange: scoreRange,
      weekdays: weekdays,
    );

    try {
      final jsonData = await _client.post(
        ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPINextDomain + ApiEndpoints.bangumiSearchNext,
          [limit, offset],
        ),
        data: params,
      );
      final jsonList = jsonData['data'];
      for (dynamic jsonItem in jsonList) {
        if (jsonItem is Map<String, dynamic>) {
          try {
            BangumiItem bangumiItem = BangumiItem.fromJson(jsonItem);
            if (bangumiItem.nameCn != '' &&
                (dateRange?.isValid != true ||
                    bangumiItem.airDate.isNotEmpty &&
                    bangumiItem.airDate.compareTo(dateRange!.start) >= 0 &&
                    bangumiItem.airDate.compareTo(dateRange.end) < 0) &&
                (scoreRange?.min == null ||
                    bangumiItem.ratingScore >= scoreRange!.min!) &&
                (scoreRange?.max == null ||
                    bangumiItem.ratingScore <= scoreRange!.max!) &&
                (weekdays.isEmpty ||
                    bangumiItem.airDate.isNotEmpty &&
                        weekdays.contains(bangumiItem.airWeekday))) {
              bangumiList.add(bangumiItem);
            }
          } catch (e) {
            KazumiLogger()
                .e('Network: resolve search results failed', error: e);
          }
        }
      }
      return BangumiSearchPage(
        items: bangumiList,
        rawCount: jsonList.length,
      );
    } catch (e) {
      KazumiLogger().e('Network: unknown search problem', error: e);
      return null;
    }
  }

  static Future<BangumiItem?> getBangumiInfoByID(int id) async =>
      (await getBangumiSubjectByID(id))?.$1;

  /// The subject as a [BangumiItem] plus the detail-page fields it lacks.
  static Future<(BangumiItem, BangumiSubjectDetail)?> getBangumiSubjectByID(
      int id) async {
    try {
      final jsonData = await _client.get(
        ApiEndpoints.formatUrl(
            ApiEndpoints.bangumiAPINextDomain +
                ApiEndpoints.bangumiInfoByIDNext,
            [id]),
      );
      return (
        BangumiItem.fromJson(jsonData),
        BangumiSubjectDetail.fromJson(jsonData),
      );
    } catch (e) {
      KazumiLogger().e('Network: resolve bangumi item failed', error: e);
      return null;
    }
  }

  static Future<List<BangumiRelation>> getBangumiRelationsByID(int id) async {
    final jsonData = await _nextSubjectRows(id, 'relations');

    final relations = <BangumiRelation>[];
    for (final jsonItem in jsonData) {
      try {
        if (jsonItem is! Map) {
          throw const FormatException('Bangumi relation must be an object');
        }
        relations.add(
          BangumiRelation.fromJson({
            ...Map<String, dynamic>.from(jsonItem['subject'] as Map),
            'name_cn': jsonItem['subject']['nameCN'],
            'relation': jsonItem['relation']['cn'],
          }),
        );
      } catch (e, stackTrace) {
        KazumiLogger().w(
          'BangumiApi: skipped malformed relation item',
          error: e,
          stackTrace: stackTrace,
        );
      }
    }
    return relations;
  }

  static Future<EpisodeInfo> getBangumiEpisodeByID(int id, int episode) async {
    EpisodeInfo episodeInfo = EpisodeInfo.fromTemplate();
    try {
      final episodes = await MainEpisodeCache.get(id);
      episodeInfo = episodes.firstWhere(
        (item) => item.displayNumber == episode,
        orElse: EpisodeInfo.fromTemplate,
      );
    } catch (e) {
      KazumiLogger().e('Network: resolve bangumi episode failed', error: e);
    }
    return episodeInfo;
  }

  static Future<List<EpisodeInfo>> getBangumiEpisodesByID(int id) async {
    final List<EpisodeInfo> episodeList = [];
    try {
      await _collectEpisodes(id, episodeList);
    } catch (e) {
      KazumiLogger()
          .e('Network: resolve bangumi episode list failed', error: e);
    }
    return episodeList;
  }

  /// Main episodes (type 0) in Bangumi's order; throws when a page fails.
  static Future<List<EpisodeInfo>> getBangumiMainEpisodesByID(int id) async {
    final List<EpisodeInfo> episodeList = [];
    await _collectEpisodes(id, episodeList, type: 0);
    return episodeList;
  }

  static Future<void> _collectEpisodes(
    int id,
    List<EpisodeInfo> episodeList, {
    int? type,
  }) async {
    const int limit = 1000;
    int offset = 0;
    int? total;
    num? firstMainSort;
    int? firstMainDisc;
    do {
      final params = <String, dynamic>{
        'type': ?type,
        'offset': offset,
        'limit': limit,
      };
      final jsonData = await _client.get(
        ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPINextDomain + ApiEndpoints.bangumiEpisodesNext,
          [id],
        ),
        queryParameters: params,
      );
      total ??= jsonData['total'] as int?;
      final data = jsonData['data'] as List<dynamic>? ?? [];
      if (data.isEmpty) {
        break;
      }
      for (final jsonItem in data.whereType<Map<String, dynamic>>()) {
        final episode = EpisodeInfo.fromJson(jsonItem);
        if (episode.type == 0) {
          final disc = (jsonItem['disc'] as num?)?.toInt() ?? 0;
          if (firstMainDisc == null ||
              disc < firstMainDisc ||
              disc == firstMainDisc && episode.episode < firstMainSort!) {
            firstMainDisc = disc;
            firstMainSort = episode.episode;
          }
        }
        // Some upstream versions ignore type=0. Paginate by the raw count,
        // but never put OP/ED/SP in the main-episode list.
        if (type == null || episode.type == type) episodeList.add(episode);
      }
      offset += data.length;
    } while (total == null || offset < total);
    // p1 omits v0's computed ep field. Preserve the same in-season numbering
    // so continuations (sort 13 -> ep 1) still match playback and watch marks.
    final first = firstMainSort;
    if (first != null) {
      for (final episode in episodeList) {
        if (episode.type == 0 && episode.seasonEpisode <= 0) {
          episode.seasonEpisode = episode.episode - first + 1;
        }
      }
    }
  }

  static Future<EpisodeCommentResponse> getBangumiCommentsByEpisodeID(
      int id) async {
    final jsonData = await _client.get(
      ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPINextDomain +
              ApiEndpoints.bangumiEpisodeCommentsByIDNext,
          [id]),
    );
    return EpisodeCommentResponse.fromJson(jsonData);
  }

  static Future<StaffResponse> getBangumiStaffByID(int id) async {
    final rows = await _nextSubjectRows(id, 'staffs/persons');
    return StaffResponse.fromJson([
      for (final row in rows.whereType<Map>())
        for (final position in row['positions'] as List? ?? const [])
          {
            ...Map<String, dynamic>.from(row['staff'] as Map),
            'relation': position['type']['cn'] ?? '',
          },
    ]);
  }

  static Future<CharactersResponse> getCharatersByBangumiID(int id) async {
    final rows = await _nextSubjectRows(id, 'characters');
    return CharactersResponse.fromJson([
      for (final row in rows.whereType<Map>())
        {
          ...Map<String, dynamic>.from(row['character'] as Map),
          'images': row['character']['images'] ?? <String, dynamic>{},
          'relation': switch (row['type']) {
            1 => '主角',
            2 => '配角',
            3 => '客串',
            _ => '未知',
          },
          'actors': [
            for (final cast in row['casts'] as List? ?? const [])
              {
                ...Map<String, dynamic>.from(cast['person'] as Map),
                'images': cast['person']['images'] ?? <String, dynamic>{},
              },
          ],
        },
    ]);
  }

  static Future<CharacterFullItem> getCharacterByCharacterID(int id) async {
    CharacterFullItem characterFullItem = CharacterFullItem.fromTemplate();
    try {
      final jsonData = await _client.get(
        ApiEndpoints.formatUrl(
            ApiEndpoints.bangumiAPINextDomain +
                ApiEndpoints.bangumiCharacterInfoByCharacterIDNext,
            [id]),
      );
      characterFullItem = CharacterFullItem.fromJson(jsonData);
    } catch (e) {
      KazumiLogger().e('Network: resolve character info failed', error: e);
    }
    return characterFullItem;
  }

  static Future<User?> getCurrentUser({String? accessToken}) async {
    try {
      final jsonData = await _client.get(
        ApiEndpoints.formatUrl(
            ApiEndpoints.bangumiAuthAPIMirrorDomain +
                ApiEndpoints.bangumiUsernameByToken,
            []),
        requiresAuth: true,
        accessToken: accessToken,
      );
      if (jsonData['id'] != null) {
        return User.fromJson(Map<String, dynamic>.from(jsonData));
      }
    } catch (e) {
      KazumiLogger().e('Network: get current user failed', error: e);
      rethrow;
    }
    return null;
  }

  static Future<List<BangumiCollection>> getBangumiCollectibles({
    List<BangumiCollectionType> includeBangumiTypes = const [
      BangumiCollectionType.planToWatch,
      BangumiCollectionType.watched,
      BangumiCollectionType.watching,
      BangumiCollectionType.onHold,
      BangumiCollectionType.abandoned,
    ],
    required String username,
    int limit = 50,
    void Function(String message, int current, int total)? onProgress,
  }) async {
    final List<BangumiCollection> bangumiCollection = [];
    int failedItemCount = 0;
    int progressCurrent = 0;
    int progressTotal = 0;

    try {
      final rateLimiter = AsyncRateLimiter(const Duration(milliseconds: 200));
      const int concurrency = 3;

      Future<Map> fetchPageData(int offset, int pageLimit) async {
        await rateLimiter.acquire();
        final url = ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAuthAPIMirrorDomain +
              ApiEndpoints.bangumiGetAllCollections,
          [username, pageLimit, offset],
        );
        final jsonData = await _client.get(url, requiresAuth: true);
        if (jsonData is! Map || jsonData['data'] is! List) {
          KazumiLogger().e(
            'BangumiApi: invalid collection response format at offset=$offset',
          );
          throw const FormatException(
              'BangumiApi: Invalid collection response format');
        }
        return jsonData;
      }

      List<BangumiCollection> parsePageItems(List<dynamic> jsonList) {
        final List<BangumiCollection> items = [];
        for (dynamic jsonItem in jsonList) {
          if (jsonItem is Map) {
            try {
              final collection = BangumiCollection.fromJson(jsonItem);
              if (includeBangumiTypes.contains(collection.type)) {
                items.add(collection);
              }
            } catch (e) {
              KazumiLogger().e(
                'BangumiApi: parse collection item failed: ${e.toString()}',
                error: e,
              );
              failedItemCount++;
            }
          }
        }
        return items;
      }

      final firstPageJson = await fetchPageData(0, limit);
      final int? rawTotal = firstPageJson['total'] as int?;
      final serverLimit = (firstPageJson['limit'] as int?) ?? limit;
      final effectiveLimit = (serverLimit > 0) ? serverLimit : limit;
      final List<dynamic> firstPageList =
          firstPageJson['data'] as List<dynamic>;

      if (rawTotal == null) {
        KazumiLogger().e(
          'BangumiApi: missing or invalid total in collection response',
        );
        throw const FormatException(
            'BangumiApi: missing total in collection response');
      }
      final int total = rawTotal;

      final firstPageReceivedCount = firstPageList.length;
      final firstPageItems = parsePageItems(firstPageList);
      bangumiCollection.addAll(firstPageItems);
      progressCurrent += firstPageList.length;

      if (total > 0 && firstPageReceivedCount == 0) {
        KazumiLogger().e(
          'BangumiApi: received empty data on first page while total > 0 (total=$total)',
        );
        throw const FormatException(
            'BangumiApi: received empty data on first page while total > 0');
      }
      progressTotal = total;
      onProgress?.call(
        '正在拉取 Bangumi 收藏',
        progressCurrent,
        progressTotal,
      );

      if (total == 0 || firstPageReceivedCount >= total) {
        KazumiLogger()
            .d('get Bangumi collection count: ${bangumiCollection.length}');
        KazumiLogger().d('get item failed count: $failedItemCount');
        return bangumiCollection;
      }

      final remainingOffsets = <int>[];
      for (int off = effectiveLimit; off < total; off += effectiveLimit) {
        remainingOffsets.add(off);
      }

      final Map<int, List<BangumiCollection>> pageResults = {};
      final offsetsQueue = List<int>.from(remainingOffsets);

      Future<void> worker() async {
        while (offsetsQueue.isNotEmpty) {
          final offset = offsetsQueue.removeAt(0);
          final pageJson = await fetchPageData(offset, effectiveLimit);
          final List<dynamic> jsonList = pageJson['data'] as List<dynamic>;
          final items = parsePageItems(jsonList);
          pageResults[offset] = items;

          progressCurrent += jsonList.length;
          onProgress?.call(
            '正在拉取 Bangumi 收藏',
            progressCurrent > progressTotal ? progressTotal : progressCurrent,
            progressTotal,
          );

          if (jsonList.length < serverLimit &&
              offset + jsonList.length >= total) {
            offsetsQueue.clear();
            break;
          }
        }
      }

      final workerCount = remainingOffsets.length < concurrency
          ? remainingOffsets.length
          : concurrency;
      await Future.wait(List.generate(workerCount, (_) => worker()));

      final Set<int> seenBangumiIds =
          bangumiCollection.map((e) => e.bangumiId).toSet();
      for (final offset in remainingOffsets) {
        final items = pageResults[offset];
        if (items != null) {
          for (final item in items) {
            if (seenBangumiIds.add(item.bangumiId)) {
              bangumiCollection.add(item);
            }
          }
        }
      }
    } catch (e) {
      KazumiLogger().e('Network: get bangumi collection failed', error: e);
      rethrow;
    }
    KazumiLogger()
        .d('get Bangumi collection count: ${bangumiCollection.length}');
    KazumiLogger().d('get item failed count: $failedItemCount');
    return bangumiCollection;
  }

  static Future<bool> updateBangumiById(
      int id, Map<String, dynamic> data) async {
    await _writeRateLimiter.acquire();
    try {
      await _client.post(
        ApiEndpoints.formatUrl(
            ApiEndpoints.bangumiAuthAPIMirrorDomain +
                ApiEndpoints.bangumiSetCollection,
            [id]),
        data: data,
        requiresAuth: true,
      );
      KazumiLogger().d('Update to Bangumi: Id: $id');
      return true;
    } on NetworkException catch (e) {
      String str;
      switch (e.statusCode) {
        case 400:
          str = 'Validation Error 验证错误';
          break;
        case 401:
          str = 'Unauthorized 未经授权';
          break;
        case 404:
          str = 'User not found 用户不存在';
          break;
        default:
          str = 'Error $e';
      }
      KazumiLogger().e('BangumiApi: $str', error: e);
      return false;
    } catch (e) {
      KazumiLogger().e('Network: update bangumi collection failed', error: e);
      rethrow;
    }
  }

  /// Marks episodes of a subject the user has collected as watched (看过).
  /// Bangumi rejects subjects outside the user's collection.
  static Future<void> markEpisodesWatched(
      int subjectId, List<int> episodeIds) =>
      _setEpisodesCollection(subjectId, episodeIds, 2);

  /// Clears the episodes' collection state on Bangumi (type 0).
  static Future<void> unmarkEpisodes(int subjectId, List<int> episodeIds) =>
      _setEpisodesCollection(subjectId, episodeIds, 0);

  static Future<void> _setEpisodesCollection(
      int subjectId, List<int> episodeIds, int type) async {
    await _writeRateLimiter.acquire();
    await _client.patch(
      ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAuthAPIMirrorDomain +
              ApiEndpoints.bangumiSetEpisodesCollection,
          [subjectId]),
      data: {'episode_id': episodeIds, 'type': type},
      requiresAuth: true,
    );
  }

  static Future<bool> updateBangumiByType(int id, int localType) async {
    final type = CollectType.fromValue(localType).toBangumiCollectionType();
    if (type == null) {
      return false;
    }
    return await updateBangumiById(id, {'type': type.value});
  }
}
