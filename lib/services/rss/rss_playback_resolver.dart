import 'package:dio/dio.dart';
import 'package:kazumi/services/api_video/api_video_models.dart';
import 'package:kazumi/services/torrent/torrent_models.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'rss_release_title_parser.dart';
import 'rss_subscription_service.dart';

class RssPlaybackCatalog {
  const RssPlaybackCatalog(this.subscription, this.releases, {this.refreshed});
  final RssSubscription subscription;
  final List<RssRelease> releases;

  /// Cached episodes can play while a stale feed is refreshed in parallel.
  final Future<RssPlaybackCatalog?>? refreshed;
  List<ApiVideoEpisode> get episodes => rssEpisodes(releases);
}

/// Adapts a single explicitly selected subtitle group to the existing player.
class RssPlaybackResolver {
  RssPlaybackResolver(this.subscriptions, this.torrents);
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
        return RssPlaybackCatalog(selected!, releases);
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
      final file = selectRssVideoFile(files, release, episode);
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

List<ApiVideoEpisode> rssEpisodes(List<RssRelease> releases) {
  final result = <String, ApiVideoEpisode>{};
  for (final release in releases) {
    if (release.isSpecial) {
      final key = 'rss-special:${release.specialKey ?? release.key}';
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
      final key = rssEpisodeKey(number);
      result.putIfAbsent(
        key,
        () => ApiVideoEpisode(key: key, title: '第 $key 话', number: number),
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
}) {
  bool matches(RssRelease release) => episode.number != null
      ? release.matchesEpisode(episode.number!)
      : release.isSpecial &&
            episode.key == 'rss-special:${release.specialKey ?? release.key}';
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
                  ? parsed.specialKey == release.specialKey
                  : parsed.episodeNumber == null
            : !parsed.isSpecial &&
                  (parsed.episodeNumber == null ||
                      parsed.episodeNumber == episode.number))) {
      return videos.single;
    }
  }
  throw const RssException('无法在种子中准确找到这一话的视频，请选择对应的单集资源');
}
