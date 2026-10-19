import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/download/download_module.dart';

/// Route arguments for '/video/'. Entry points hand playback context over
/// through the route instead of pre-filling a shared controller, which lets
/// [VideoPageController] live and die with the route.
sealed class VideoPlaybackArgs {
  const VideoPlaybackArgs({required this.bangumiItem});

  final BangumiItem bangumiItem;
}

class OnlineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OnlineVideoPlaybackArgs({
    required super.bangumiItem,
    this.initialEpisode,
    this.initialOffset,
    this.initialEpisodePageUrl,
    this.startEpisodeNumber,
    this.playbackSource,
    this.rememberPlaybackSource = true,
    this.rssReleaseId,
    this.rssEpisodeNumber,
    this.torrentTaskId,
    this.torrentFileIndex,
  });

  final int? initialEpisode;
  final int? initialOffset;

  /// A per-navigation choice; null follows the saved playback preference.
  final String? playbackSource;

  /// False for a source inferred from old history rather than a user choice.
  final bool rememberPlaybackSource;
  final String? rssReleaseId;
  final double? rssEpisodeNumber;
  final String? torrentTaskId;
  final int? torrentFileIndex;

  /// An episode the user picked by its number (第 N 话); plays it from the
  /// start instead of resuming the watch history.
  final int? startEpisodeNumber;

  /// Stable identity retained when a provider omits earlier episodes. Legacy
  /// website URLs allow the player to fall back to the saved list position.
  final String? initialEpisodePageUrl;
}

class OfflineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OfflineVideoPlaybackArgs({
    required super.bangumiItem,
    required this.pluginName,
    required this.episodeNumber,
    required this.road,
    required this.downloadedEpisodes,
  });

  final String pluginName;
  final int episodeNumber;
  final int road;
  final List<DownloadEpisode> downloadedEpisodes;
}
