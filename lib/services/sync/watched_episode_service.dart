import 'dart:async';

import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bangumi/airing_summary.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/request/apis/main_episode_cache.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

/// Acts once per episode when playback passes most of it, and only for shows
/// the user added to 追番 themselves: marks the episode as watched on Bangumi
/// and, after the final episode of a finished show, offers to mark it 看过.
/// Playing never adds a show to 追番.
class WatchedEpisodeService {
  WatchedEpisodeService(this._collectController);

  static const _watchedShare = 0.9;

  final CollectController _collectController;
  final _handled = <String>{};

  void report(
    PlaybackHistoryIdentity identity,
    Duration position,
    Duration duration, {
    int? episodeNumber,
  }) {
    if (duration <= Duration.zero ||
        position.inMilliseconds < duration.inMilliseconds * _watchedShare) {
      return;
    }
    final item = identity.bangumiItem;
    final number = episodeNumber ?? identity.episodeNumber;
    if (number <= 0 || !_handled.add('${item.id}:$number')) return;
    unawaited(_onWatched(item, number));
  }

  Future<void> _onWatched(BangumiItem item, int episodeNumber) async {
    final type = CollectType.fromValue(_collectController.getCollectType(item));
    if (!type.isCollected) return;
    final List<EpisodeInfo> episodes;
    try {
      episodes = await MainEpisodeCache.get(item.id);
    } catch (e) {
      KazumiLogger().w('WatchedEpisode: episode list unavailable', error: e);
      return;
    }

    final episode = _episodeFor(episodes, episodeNumber);
    if (episode != null && _syncEpisodes) {
      try {
        await BangumiApi.markEpisodesWatched(item.id, [episode.id]);
      } catch (e) {
        KazumiLogger().w(
          'WatchedEpisode: Bangumi episode sync failed',
          error: e,
        );
      }
    }

    if (type == CollectType.watching) {
      final summary = AiringSummary.of(episodes, today: DateTime.now());
      if (summary.finished && episodeNumber >= summary.total) {
        _offerWatched(item);
      }
    }
  }

  static EpisodeInfo? _episodeFor(List<EpisodeInfo> episodes, int number) {
    for (final episode in episodes) {
      if (episode.displayNumber == number) return episode;
    }
    return number >= 1 && number <= episodes.length
        ? episodes[number - 1]
        : null;
  }

  bool get _syncEpisodes =>
      GStorage.getSetting(SettingsKeys.bangumiSyncEnable) &&
      GStorage.getSetting(SettingsKeys.bangumiEpisodeSyncEnable) &&
      GStorage.getSetting(SettingsKeys.bangumiAccessToken).trim().isNotEmpty;

  void _offerWatched(BangumiItem item) {
    final title = item.nameCn.isNotEmpty ? item.nameCn : item.name;
    KazumiDialog.showToast(
      message: '《$title》已看完',
      showActionButton: true,
      actionLabel: '标记为看过',
      duration: const Duration(seconds: 8),
      onActionPressed: () async {
        try {
          await _collectController.addCollect(
            item,
            type: CollectType.watched.value,
          );
        } catch (_) {
          KazumiDialog.showToast(message: '修改收藏状态失败，请稍后重试');
        }
      },
    );
  }
}
