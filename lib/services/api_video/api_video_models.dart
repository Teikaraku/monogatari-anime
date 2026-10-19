import 'package:kazumi/services/video_source/video_source_format.dart';
import 'episode_identity.dart';

const apiPlaybackLibraryName = '自动播放';

enum ApiVideoProvider {
  zy1080('zy1080', '优质（1080zyk4）'),
  baofeng('baofeng', '暴风'),
  liangzi('liangzi', '量子');

  const ApiVideoProvider(this.id, this.name);

  final String id;
  final String name;
}

const apiVideoProviderPriority = [
  ApiVideoProvider.zy1080,
  ApiVideoProvider.baofeng,
  ApiVideoProvider.liangzi,
];

/// A source-independent episode. Unnumbered extras retain distinct keys.
class ApiVideoEpisode {
  const ApiVideoEpisode({required this.key, required this.title, this.number});

  final String key;
  final String title;
  final double? number;
}

String apiEpisodePageUrl(int bangumiId, ApiVideoEpisode episode) =>
    'monogatari://episode/$bangumiId/${Uri.encodeComponent(canonicalEpisodeKey(episode.key))}';

class ApiVideoCatalog {
  const ApiVideoCatalog({
    required this.provider,
    required this.id,
    required this.title,
    required this.episodes,
  });

  final ApiVideoProvider provider;
  final String id;
  final String title;
  final List<ApiVideoEpisode> episodes;

  String get matchedTitle => title;
}

class ApiVideoCandidate {
  const ApiVideoCandidate({
    required this.provider,
    required this.id,
    required this.title,
    required this.episode,
    required this.url,
    required this.format,
    this.httpHeaders = const {},
    this.adBlocker = true,
  });

  final ApiVideoProvider provider;
  final String id;
  final String title;
  final ApiVideoEpisode episode;
  final String url;
  final Map<String, String> httpHeaders;
  final VideoSourceFormat format;
  final bool adBlocker;

  String get matchedTitle => title;
  String get identity => '${provider.id}/$id/${episode.key}/$url';
}

enum ApiVideoFailure { network, timeout, blocked, invalidResponse }

class ApiVideoUnavailableException implements Exception {
  const ApiVideoUnavailableException([
    this.message = '暂未找到与本番匹配的剧集',
    this.failure,
  ]);
  final ApiVideoFailure? failure;

  factory ApiVideoUnavailableException.fromFailures(
    Iterable<ApiVideoFailure?> failures,
  ) {
    final known = failures.whereType<ApiVideoFailure>().toSet();
    for (final failure in [
      ApiVideoFailure.network,
      ApiVideoFailure.timeout,
      ApiVideoFailure.blocked,
      ApiVideoFailure.invalidResponse,
    ]) {
      if (!known.contains(failure)) continue;
      return ApiVideoUnavailableException(switch (failure) {
        ApiVideoFailure.network => '片源连接失败，请检查网络后重试；暂时无法确认是否有资源',
        ApiVideoFailure.timeout => '片源请求超时，请稍后重试；暂时无法确认是否有资源',
        ApiVideoFailure.blocked => '片源被访问验证或限流拦截，请稍后重试',
        ApiVideoFailure.invalidResponse => '片源返回的数据无效或过大，请稍后重试',
      }, failure);
    }
    return const ApiVideoUnavailableException();
  }

  final String message;

  @override
  String toString() => message;
}
