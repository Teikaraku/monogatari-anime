import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart'
    show RuleCancelToken;

sealed class HistoryPlaybackResult {
  const HistoryPlaybackResult();
}

class HistoryPlaybackReady extends HistoryPlaybackResult {
  const HistoryPlaybackReady(this.args);

  final VideoPlaybackArgs args;
}

class HistoryPlaybackUnavailable extends HistoryPlaybackResult {
  const HistoryPlaybackUnavailable(this.reason);

  final String reason;
}

/// Restores a history entry into arguments the player route can take.
///
/// The history page and the my page share this one resolution path; cards
/// carry no source-lookup logic of their own.
class HistoryPlaybackService {
  HistoryPlaybackService(this._downloadController);
  final DownloadController _downloadController;

  /// Keeps the caller's cancellation contract. Resource lookup happens in the
  /// player and is independent of the source saved by older app versions.
  Future<HistoryPlaybackResult> open(
    History history, {
    RuleCancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    if (HistoryEntryKind.normalize(history.entryKind) ==
        HistoryEntryKind.offline) {
      final args = _offlineArgs(history);
      return args == null
          ? const HistoryPlaybackUnavailable('未找到可用缓存')
          : HistoryPlaybackReady(args);
    }

    final episode = history.lastWatchEpisode > 0 ? history.lastWatchEpisode : 1;
    final seconds = history.progresses[episode]?.progress.inSeconds ?? 0;
    final key = _stableEpisodeKey(
      history.episodePageUrl,
      history.bangumiItem.id,
    );
    final torrentMatch = RegExp(
      r'^torrent:([a-fA-F0-9]{40}):(0|[1-9][0-9]*)$',
    ).firstMatch(key ?? '');
    final fileIndex = torrentMatch == null
        ? null
        : int.tryParse(torrentMatch[2]!);
    final taskId = fileIndex == null ? null : torrentMatch![1]!.toLowerCase();
    final isRssSpecial =
        key != null &&
        key.startsWith('rss-special:') &&
        key.length > 'rss-special:'.length;
    return HistoryPlaybackReady(
      OnlineVideoPlaybackArgs(
        bangumiItem: history.bangumiItem,
        initialEpisode: episode,
        initialOffset: seconds > 0 ? seconds : 0,
        initialEpisodePageUrl: history.episodePageUrl,
        playbackSource: taskId != null || isRssSpecial ? 'rss' : null,
        rememberPlaybackSource: false,
        torrentTaskId: taskId,
        torrentFileIndex: fileIndex,
      ),
    );
  }

  VideoPlaybackArgs? _offlineArgs(History history) {
    final downloadedEpisodes = _downloadController.getCompletedEpisodes(
      history.bangumiItem.id,
      history.adapterName,
    );
    if (downloadedEpisodes.isEmpty) {
      return null;
    }

    // The page url pins the exact episode; the number is the legacy fallback.
    DownloadEpisode? targetEpisode;
    DownloadEpisode? numberMatch;
    for (final episode in downloadedEpisodes) {
      if (history.episodePageUrl.isNotEmpty &&
          episode.episodePageUrl == history.episodePageUrl) {
        targetEpisode = episode;
        break;
      }
      if (episode.episodeNumber == history.lastWatchEpisode) {
        numberMatch ??= episode;
      }
    }
    // A synchronized API slot can belong to a different episode locally.
    // Only legacy history may fall back to its numeric position.
    if (targetEpisode == null &&
        history.episodePageUrl.startsWith('monogatari://episode/')) {
      return null;
    }
    targetEpisode ??= numberMatch;
    if (targetEpisode == null) {
      return null;
    }

    final localPath = _downloadController.getLocalVideoPath(
      history.bangumiItem.id,
      history.adapterName,
      targetEpisode.episodeNumber,
    );
    if (localPath == null) {
      return null;
    }

    return OfflineVideoPlaybackArgs(
      bangumiItem: history.bangumiItem,
      pluginName: history.adapterName,
      episodeNumber: targetEpisode.episodeNumber,
      road: targetEpisode.road,
      downloadedEpisodes: downloadedEpisodes,
    );
  }
}

String? _stableEpisodeKey(String value, int subjectId) {
  try {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'monogatari' ||
        uri.host != 'episode' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final segments = uri.pathSegments;
    if (segments.length != 2 || segments.first != '$subjectId') return null;
    return segments[1];
  } on FormatException {
    return null;
  }
}
