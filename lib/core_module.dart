import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/services/subject/subject_local_store.dart';
import 'package:kazumi/services/sync/rss_sync_service.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/repositories/collect_repository.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/repositories/danmaku_shield_repository.dart';
import 'package:kazumi/repositories/history_repository.dart';
import 'package:kazumi/repositories/search_history_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/api_video/api_video_service.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/services/player/history_playback_service.dart';
import 'package:kazumi/services/player/playback_source_preferences.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/services/sync/danmaku_shield_sync_service.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:kazumi/services/rss/rss_subscription_service.dart';
import 'package:kazumi/services/rss/rss_playback_resolver.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:kazumi/services/torrent/torrent_network_policy.dart';
import 'package:kazumi/services/torrent/dart_torrent_engine.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/request/apis/main_episode_cache.dart';
import 'package:kazumi/services/torrent/torrent_background_coordinator.dart';
import 'package:kazumi/navigation.dart';

/// Root-owned application data and cross-feature coordinators.
///
/// This module intentionally has no path, so its registrations live for the
/// whole application. Page and feature-local state belongs in route `provide`
/// callbacks or path-bearing modules instead.
final coreModule = createModule(
  register: (c) {
    c
      // Repository layer.
      ..addSingleton<ICollectRepository>(CollectRepository.new)
      ..addSingleton<ISearchHistoryRepository>(SearchHistoryRepository.new)
      ..addSingleton<ICollectCrudRepository>(CollectCrudRepository.new)
      ..addSingleton<IHistoryRepository>(() => HistoryRepository())
      ..addSingleton<IDownloadRepository>(DownloadRepository.new)
      ..addSingleton<IDanmakuShieldRepository>(DanmakuShieldRepository.new)
      // Service layer.
      ..addSingleton<ApiVideoService>(() => ApiVideoService())
      ..addSingleton<SubjectNotes>(SubjectNotes.new)
      ..addSingleton<EpisodeMarks>(EpisodeMarks.new)
      ..addSingleton<SubjectPlayerChoices>(SubjectPlayerChoices.new)
      ..addSingleton<PlaybackSourcePreferences>(
        () => PlaybackSourcePreferences(),
      )
      ..addSingleton<RssSubscriptionService>(() => RssSubscriptionService())
      ..addSingleton<TorrentService>(
        () => TorrentService(
          networkAllowed: torrentNetworkAllowed,
          engine: DartTorrentEngine(
            metadataProxy: (uri) =>
                NetworkConfig.fromSettings().proxyForUri(uri)?.toString(),
            uploadLimit: torrentUploadLimit,
          ),
        ),
      )
      ..addSingleton<RssPlaybackResolver>((RssSubscriptionService subscriptions,
          TorrentService torrents) => RssPlaybackResolver(subscriptions, torrents,
            loadEpisodes: MainEpisodeCache.get))
      ..addSingleton<TorrentBackgroundCoordinator>(_createTorrentBackground)
      ..addSingleton<IDownloadManager>(() => DownloadManager())
      ..addSingleton<AudioController>(AudioController.new)
      ..addSingleton<HistoryPlaybackService>(HistoryPlaybackService.new)
      ..addSingleton<ShaderAssetService>(ShaderAssetService.new)
      ..addSingleton<WebDav>(WebDav.new)
      ..addSingleton<DanmakuShieldSyncService>(DanmakuShieldSyncService.new)
      ..addSingleton<RssSyncService>(RssSyncService.new)
      // Cross-feature state and coordinators.
      ..addSingleton<CollectController>(CollectController.new)
      ..addSingleton<HistoryController>(HistoryController.new)
      ..addSingleton<MyController>(MyController.new)
      ..addSingleton<DownloadController>(DownloadController.new);
  },
);

TorrentBackgroundCoordinator _createTorrentBackground(
  TorrentService torrents,
) => TorrentBackgroundCoordinator(
  torrents,
  onNotice: (message) => KazumiDialog.showToast(message: message),
  onNavigateRequested: () {
    final context = rootNavigatorKey.currentContext;
    if (context != null &&
        context.mounted &&
        !context
            .routeState(listen: false)
            .uri
            .path
            .contains('/torrent-tasks')) {
      context.pushNamed('/torrent-tasks/');
    }
  },
);
