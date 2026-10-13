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
  });

  final int? initialEpisode;
  final int? initialOffset;

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
