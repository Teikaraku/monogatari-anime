import 'package:dio/dio.dart';
import 'package:kazumi/services/api_video/api_video_models.dart';
import 'package:kazumi/services/torrent/torrent_models.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/services/api_video/episode_identity.dart';
import 'rss_release_title_parser.dart';
import 'rss_subscription_service.dart';

class RssPlaybackCatalog {
  const RssPlaybackCatalog(
    this.subscription,
    this.releases, {
    this.refreshed,
    this.episodeNumbers = const {},
  });
  final RssSubscription subscription;
  final List<RssRelease> releases;
  final Map<double, double> episodeNumbers;

  /// Cached episodes can play while a stale feed is refreshed in parallel.
  final Future<RssPlaybackCatalog?>? refreshed;
  List<ApiVideoEpisode> get episodes =>
      rssEpisodes(releases, episodeNumbers: episodeNumbers);
}

/// Adapts a single explicitly selected subtitle group to the existing player.
class RssPlaybackResolver {
  RssPlaybackResolver(this.subscriptions, this.torrents, {this.loadEpisodes});
  final Future<List<EpisodeInfo>> Function(int)? loadEpisodes;
  final RssSubscriptionService subscriptions;
  final TorrentService torrents;

  Future<RssPlaybackCatalog> load(
    int subjectId, {
    CancelToken? cancelToken,
  }) async {
    await subscriptions.initialize();
    _checkCancelled(cancelToken);
    final subscription = subscriptions.subscriptionForSubject(subjectId);
    if (subscription == null) {
      throw const RssException('请先订阅本番的字幕组，并选择用于播放的订阅');
    }
    final cached = subscriptions.releasesForSubject(
      subjectId,
      subscriptionId: subscription.id,
    );
    var numbering = const <double, double>{};
    if (loadEpisodes != null) {
      try {
        numbering = rssSeasonNumbering(
          await loadEpisodes!(subjectId).timeout(const Duration(seconds: 6)),
        );
      } catch (_) {
        // Without verified season metadata, retain source numbers. Never
        // shift from the first available release: earlier episodes may be missing.
      }
      _checkCancelled(cancelToken);
    }
    final hasCache = rssEpisodes(cached).isNotEmpty;
    final last = subscription.lastRefreshedAt;
    final stale =
        last == null ||
        DateTime.now().difference(last) > const Duration(minutes: 15);
    Future<RssPlaybackCatalog?> refresh() async {
      try {
        await subscriptions.refresh(
          subscriptionId: subscription.id,
          cancelToken: cancelToken,
        );
        _checkCancelled(cancelToken);
        final selected = subscriptions.subscriptionForSubject(subjectId);
        if (selected?.id != subscription.id) return null;
        final releases = subscriptions.releasesForSubject(
          subjectId,
          subscriptionId: subscription.id,
        );
        if (rssEpisodes(releases).isEmpty) return null;
        return RssPlaybackCatalog(
          selected!,
          releases,
          episodeNumbers: numbering,
        );
      } catch (_) {
        // The subscription service exposes refresh errors. Existing verified
        // releases remain usable even when the feed is temporarily offline.
        return null;
      }
    }

    if (hasCache) {
      return RssPlaybackCatalog(
        subscription,
        cached,
        refreshed: stale ? refresh() : null,
        episodeNumbers: numbering,
      );
    }
    final updated = await refresh();
    _checkCancelled(cancelToken);
    final releases = updated?.releases ?? const <RssRelease>[];
    if (rssEpisodes(releases).isEmpty) {
      throw const RssException('当前字幕组没有可识别集数的资源，请在订阅中检查资源');
    }
    return updated!;
  }

  Future<TorrentPlaybackLease> open(
    RssPlaybackCatalog catalog,
    ApiVideoEpisode episode, {
    String? releaseId,
    bool downloadWhilePlaying = false,
    required CancelToken cancelToken,
    void Function(String)? onStatus,
  }) async {
    final release = selectRssRelease(
      catalog.releases,
      episode,
      releaseId: releaseId,
      episodeNumbers: catalog.episodeNumbers,
    );
    final sourceNumbers = episode.number == null
        ? const <double>{}
        : [
                if (release.episodeNumber != null) release.episodeNumber!,
                ...release.episodeNumbers,
              ]
              .where(
                (number) =>
                    (catalog.episodeNumbers[number] ?? number) ==
                    episode.number,
              )
              .toSet();
    if (episode.number != null && sourceNumbers.length != 1) {
      throw const RssException('此资源包含多套集数编号，无法准确定位，请选择单集资源');
    }
    final sourceNumber = sourceNumbers.singleOrNull;
    final sourceEpisode = ApiVideoEpisode(
      key: episode.key,
      title: episode.title,
      number: sourceNumber,
    );
    onStatus?.call('正在获取种子信息 · ${catalog.subscription.group.name}');
    final task = await torrents.add(
      release.sourceUri,
      title: release.title,
      bangumiId: catalog.subscription.bangumiId,
      episodeNumber: episode.number,
      releaseKey: release.key,
      subjectData: rssSubjectToJson(catalog.subscription.subject),
      cancelToken: cancelToken,
    );
    try {
      _checkCancelled(cancelToken);
      final files = await torrents.waitForMetadata(
        task.id,
        cancelToken: cancelToken,
      );
      _checkCancelled(cancelToken);
      final file = selectRssVideoFile(files, release, sourceEpisode);
      onStatus?.call('正在连接做种者并缓冲视频 · ${catalog.subscription.group.name}');
      final lease = await torrents.openStream(
        task.id,
        file.index,
        cancelToken: cancelToken,
        downloadWhilePlaying: downloadWhilePlaying,
      );
      if (cancelToken.isCancelled) {
        await lease.close();
        _checkCancelled(cancelToken);
      }
      return lease;
    } catch (_) {
      try {
        await torrents.releaseTemporary(task.id);
      } catch (error) {
        KazumiLogger().w('Temporary RSS task cleanup failed', error: error);
      }
      rethrow;
    }
  }
}

void _checkCancelled(CancelToken? token) {
  if (token?.isCancelled == true) throw token!.cancelError!;
}

String rssEpisodeKey(double number) =>
    number == number.truncateToDouble() ? '${number.toInt()}' : '$number';

Map<double, double> rssSeasonNumbering(List<EpisodeInfo> episodes) => {
  for (final episode in episodes)
    if (episode.type == 0 && episode.episode > 0 && episode.displayNumber > 0)
      episode.episode.toDouble(): episode.displayNumber.toDouble(),
};

List<ApiVideoEpisode> rssEpisodes(
  List<RssRelease> releases, {
  Map<double, double> episodeNumbers = const {},
}) {
  final result = <String, ApiVideoEpisode>{};
  for (final release in releases) {
    if (release.isSpecial) {
      final key = specialEpisodeKey(release.specialKey ?? release.key);
      result.putIfAbsent(
        key,
        () => ApiVideoEpisode(key: key, title: release.title),
      );
      continue;
    }
    for (final number in [
      if (release.episodeNumber != null) release.episodeNumber!,
      ...release.episodeNumbers,
    ]) {
      final localNumber = episodeNumbers[number] ?? number;
      final key = rssEpisodeKey(localNumber);
      result.putIfAbsent(
        key,
        () => ApiVideoEpisode(key: key, title: '第 $key 话', number: localNumber),
      );
    }
  }
  return result.values.toList()..sort((a, b) {
    if (a.number == null) return b.number == null ? a.key.compareTo(b.key) : 1;
    return b.number == null ? -1 : a.number!.compareTo(b.number!);
  });
}

RssRelease selectRssRelease(
  List<RssRelease> releases,
  ApiVideoEpisode episode, {
  String? releaseId,
  Map<double, double> episodeNumbers = const {},
}) {
  bool matches(RssRelease release) => episode.number != null
      ? [
          if (release.episodeNumber != null) release.episodeNumber!,
          ...release.episodeNumbers,
        ].any((number) => (episodeNumbers[number] ?? number) == episode.number)
      : release.isSpecial &&
            canonicalEpisodeKey(episode.key) ==
                specialEpisodeKey(release.specialKey ?? release.key);
  final matching = releases.where(matches).toList();
  if (releaseId != null) {
    final explicit = matching.where((r) => r.key == releaseId);
    if (explicit.isEmpty) throw const RssException('所选资源不属于当前字幕组或不包含这一话，请重新选择');
    return explicit.first;
  }
  // Prefer one-episode releases over whole-season batches; newer revisions
  // within that class supersede old releases without crossing groups.
  matching.sort((a, b) {
    if (a.isBatch != b.isBatch) return a.isBatch ? 1 : -1;
    return (b.publishedAt ?? DateTime(1970)).compareTo(
      a.publishedAt ?? DateTime(1970),
    );
  });
  if (matching.isEmpty) throw const RssException('当前字幕组尚未发布这一话');
  return matching.first;
}

TorrentFileInfo selectRssVideoFile(
  List<TorrentFileInfo> files,
  RssRelease release,
  ApiVideoEpisode episode,
) {
  final videos = files
      .where(
        (file) =>
            file.isVideo &&
            !RegExp(
              r'(^|[\\/\s_.\[\]-])(sample|trailer|pv|cm|ncop|nced)([\\/\s_.\[\]\d-]|$)',
              caseSensitive: false,
            ).hasMatch(file.name),
      )
      .toList();
  if (episode.number != null) {
    final exact = videos.where((file) {
      final name = file.name
          .split(RegExp(r'[/\\]'))
          .last
          .replaceFirst(RegExp(r'\.[^.]+$'), '');
      final parsed = parseRssReleaseTitle(name);
      return !parsed.isSpecial &&
          !parsed.isBatch &&
          parsed.episodeNumber == episode.number;
    }).toList();
    if (exact.length == 1) return exact.single;
    if (exact.length > 1) throw const RssException('种子中同一话有多个视频版本，请选择单集资源');
  }
  if (videos.length == 1 &&
      !release.isBatch &&
      (release.isSpecial || release.episodeNumber == episode.number)) {
    // An opaque single-file name is safe only when the feed identifies one
    // episode. A clearly conflicting filename must still be rejected.
    final name = videos.single.name
        .split(RegExp(r'[/\\]'))
        .last
        .replaceFirst(RegExp(r'\.[^.]+$'), '');
    final parsed = parseRssReleaseTitle(name);
    if (!parsed.isBatch &&
        (release.isSpecial
            ? parsed.isSpecial
                  ? specialEpisodeKey(parsed.specialKey ?? '') ==
                        specialEpisodeKey(release.specialKey ?? '')
                  : parsed.episodeNumber == null
            : !parsed.isSpecial &&
                  (parsed.episodeNumber == null ||
                      parsed.episodeNumber == episode.number))) {
      return videos.single;
    }
  }
  throw const RssException('无法在种子中准确找到这一话的视频，请选择对应的单集资源');
}
