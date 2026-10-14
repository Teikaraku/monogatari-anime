import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/services/api_video/api_video_service.dart';
import 'package:kazumi/services/api_video/episode_identity.dart';
import 'package:kazumi/services/player/automatic_playback_runner.dart';
import 'package:kazumi/services/player/media_startup_gate.dart';
import 'package:kazumi/services/player/playback_source_preferences.dart';
import 'package:kazumi/services/player/rss_playback_status.dart';
import 'package:kazumi/services/player/playback_stall_monitor.dart';
import 'package:kazumi/services/rss/rss_playback_resolver.dart';
import 'package:kazumi/services/rss/rss_models.dart';
import 'package:kazumi/services/torrent/torrent_models.dart';
import 'package:kazumi/services/torrent/torrent_playback_catalog.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/modules/comments/comment_item.dart';
import 'package:kazumi/modules/comments/comment_response.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/media.dart';
import 'package:kazumi/utils/async_session.dart';
import 'package:kazumi/services/platform/display_mode_service.dart';
import 'package:kazumi/pages/video/video_fullscreen_controller.dart';

part 'video_controller.g.dart';

class VideoPageController extends _VideoPageController
    with _$VideoPageController {
  VideoPageController(
    super.historyController,
    super.downloadRepository,
    super.downloadManager,
    super.apiVideoService, {
    super.rssPlayback,
    super.playbackPreferences,
  });
  VideoPageController.withRss(
    super.history,
    super.downloads,
    super.downloadManager,
    super.api,
    RssPlaybackResolver rss,
    PlaybackSourcePreferences preferences,
  ) : super(rssPlayback: rss, playbackPreferences: preferences);
}

class VideoEpisodeSelection {
  const VideoEpisodeSelection({required this.episode, required this.road});

  final int episode;
  final int road;

  @override
  bool operator ==(Object other) {
    return other is VideoEpisodeSelection &&
        other.episode == episode &&
        other.road == road;
  }

  @override
  int get hashCode => Object.hash(episode, road);

  @override
  String toString() {
    return 'VideoEpisodeSelection(episode: $episode, road: $road)';
  }
}

abstract class _VideoPageController with Store implements Disposable {
  _VideoPageController(
    this.historyController,
    this.downloadRepository,
    this.downloadManager,
    this.apiVideoService, {
    this.rssPlayback,
    PlaybackSourcePreferences? playbackPreferences,
  }) : playbackPreferences = playbackPreferences ?? PlaybackSourcePreferences();

  late BangumiItem bangumiItem;
  EpisodeInfo episodeInfo = EpisodeInfo.fromTemplate();

  @observable
  var episodeCommentsList = ObservableList<EpisodeCommentItem>();

  // Resolution state machine: [_beginEpisodeSwitch] enters the loading state;
  // [_finishLoading] and [_failLoading] are the only terminal transitions.
  // [_errorMessage] is non-null only in the failed state.
  @readonly
  bool _loading = true;

  @readonly
  String? _errorMessage;

  @observable
  VideoEpisodeSelection selectedEpisode = const VideoEpisodeSelection(
    episode: 1,
    road: 0,
  );

  @observable
  VideoEpisodeSelection? playingEpisode;

  @observable
  int commentsEpisode = 1;

  @action
  void resetEpisodeState({int episode = 1, int road = 0}) {
    final selection = VideoEpisodeSelection(episode: episode, road: road);
    selectedEpisode = selection;
    playingEpisode = null;
    commentsEpisode = commentEpisodeForSelection(selection);
  }

  VideoEpisodeSelection get playbackEpisode =>
      playingEpisode ?? selectedEpisode;

  final fullscreen = VideoFullscreenController(
    applyFullscreen: DisplayModeService.applyVideoFullscreen,
  );

  bool get isFullscreen => fullscreen.isFullscreen;

  @observable
  bool isCommentsAscending = false;

  // Playback, automatic danmaku loading, and comment loading have separate
  // owners. Manual danmaku selection can cancel auto danmaku without touching
  // playback; comment refreshes never cancel playback.
  final AsyncSessionOwner _playbackSessions = AsyncSessionOwner();
  final AsyncSessionOwner _onlineStartupSessions = AsyncSessionOwner();
  final AsyncSessionOwner _danmakuSessions = AsyncSessionOwner();
  final AsyncSessionOwner _commentSessions = AsyncSessionOwner();

  @observable
  bool isPip = false;

  @observable
  int historyOffset = 0;

  @observable
  bool isOfflineMode = false;

  PlaybackHistoryIdentity? _playbackHistoryIdentity;
  final Map<int, DownloadEpisode> _offlineEpisodesByNumber = {};
  final Map<int, int> _offlineDisplayRoadToOriginalRoad = {};
  final Map<int, int> _offlineOriginalRoadToDisplayRoad = {};

  /// Title reported by the video source; may differ from [bangumiItem]'s.
  String title = '';

  String src = '';

  @observable
  var roadList = ObservableList<Road>();

  List<ApiVideoEpisode> apiEpisodes = const [];

  final RssPlaybackResolver? rssPlayback;
  final PlaybackSourcePreferences playbackPreferences;
  RssPlaybackCatalog? _rssCatalog;
  TorrentPlaybackLease? _torrentLease;
  String? _requestedRssRelease;
  double? _requestedRssEpisode;
  String? _directTorrentTaskId;
  int? _requestedTorrentFile;
  final Map<String, int> _torrentFiles = {};
  bool _rssRecovering = false;

  @observable
  String playbackSource = 'api';

  @observable
  String playbackStatus = '';

  bool get isRssPlayback => !isOfflineMode && playbackSource == 'rss';
  bool get isDirectTorrentPlayback =>
      isRssPlayback && _directTorrentTaskId != null;

  int? get requestedRssEpisodeIndex {
    if (_directTorrentTaskId != null) {
      final index = apiEpisodes.indexWhere(
        (episode) => _torrentFiles[episode.key] == _requestedTorrentFile,
      );
      return index < 0 ? null : index + 1;
    }
    if (!isRssPlayback || _rssCatalog == null || _requestedRssRelease == null) {
      return null;
    }
    final releases = _rssCatalog!.releases.where(
      (r) => r.key == _requestedRssRelease,
    );
    if (releases.isEmpty) return null;
    final release = releases.first;
    final key = release.isSpecial
        ? specialEpisodeKey(release.specialKey ?? release.key)
        : (_requestedRssEpisode ?? release.episodeNumber) == null
        ? null
        : rssEpisodeKey(
            _rssCatalog?.episodeNumbers[_requestedRssEpisode ??
                    release.episodeNumber] ??
                (_requestedRssEpisode ?? release.episodeNumber)!,
          );
    final index = apiEpisodes.indexWhere((episode) => episode.key == key);
    return index < 0 ? null : index + 1;
  }

  void rejectRssRelease() => _failLoading('所选资源不在当前字幕组中，或需要先选择合集集数');

  String _offlinePluginName = '';

  final HistoryController historyController;
  final IDownloadRepository downloadRepository;
  final IDownloadManager downloadManager;
  final ApiVideoService apiVideoService;
  CancelToken? _catalogCancellation;
  StreamSubscription<List<ApiVideoEpisode>>? _catalogUpdates;
  Future<void>? _catalogExpansionDone;
  CancelToken? _playbackCancellation;
  AutomaticPlaybackRunner<ApiVideoCandidate>? _automaticPlayback;
  PlayerController? _activePlayerController;
  Completer<bool>? _pendingOpen;
  final List<StreamSubscription<dynamic>> _mediaSubscriptions = [];
  Timer? _startupTimer;
  Timer? _bufferingTimer;
  StreamSubscription<List<TorrentTaskSnapshot>>? _torrentProgress;

  final StreamController<String> _logStreamController =
      StreamController<String>.broadcast();

  Stream<String> get logStream => _logStreamController.stream;

  AsyncSession beginOnlineStartup() => _onlineStartupSessions.begin();

  /// Applies the route arguments exactly once, from [VideoPage.initState].
  @action
  void applyPlaybackArgs(VideoPlaybackArgs args) {
    switch (args) {
      case OnlineVideoPlaybackArgs():
        bangumiItem = args.bangumiItem;
        title = bangumiItem.nameCn.isNotEmpty
            ? bangumiItem.nameCn
            : bangumiItem.name;
        src = 'monogatari://subject/${bangumiItem.id}';
        final savedSource = playbackPreferences.forSubject(bangumiItem.id);
        playbackSource =
            ((args.rememberPlaybackSource
                        ? args.playbackSource ?? savedSource
                        : savedSource ?? args.playbackSource) ??
                    GStorage.getSetting(SettingsKeys.playbackSource)) ==
                'rss'
            ? 'rss'
            : 'api';
        if (args.rememberPlaybackSource && args.playbackSource != null) {
          _rememberPlaybackSource(playbackSource);
        }
        _requestedRssRelease = args.rssReleaseId;
        _requestedRssEpisode = args.rssEpisodeNumber;
        _directTorrentTaskId = isRssPlayback ? args.torrentTaskId : null;
        _requestedTorrentFile = isRssPlayback ? args.torrentFileIndex : null;
        roadList.clear();
      case OfflineVideoPlaybackArgs():
        _initForOfflinePlayback(
          bangumiItem: args.bangumiItem,
          pluginName: args.pluginName,
          episodeNumber: args.episodeNumber,
          road: args.road,
          downloadedEpisodes: args.downloadedEpisodes,
        );
    }
  }

  Future<bool> initializeOnline() async {
    _catalogCancellation?.cancel();
    final previousUpdates = _catalogUpdates;
    _catalogUpdates = null;
    final cancellation = CancelToken();
    _catalogCancellation = cancellation;
    await previousUpdates?.cancel();
    if (cancellation.isCancelled) return false;
    try {
      if (isRssPlayback) {
        final resolver = rssPlayback;
        if (resolver == null) throw const RssException('RSS 播放服务尚未初始化');
        if (_directTorrentTaskId != null) {
          await resolver.torrents.initialize();
          if (cancellation.isCancelled) return false;
          final task = resolver.torrents.tasks
              .where((task) => task.id == _directTorrentTaskId)
              .firstOrNull;
          if (task == null || task.bangumiId != bangumiItem.id) {
            throw const RssException('磁力任务不存在或不属于当前番剧');
          }
          final entries = torrentPlaybackCatalog(task);
          _torrentFiles.clear();
          _torrentFiles.addEntries(
            entries.map(
              (entry) => MapEntry(entry.episode.key, entry.fileIndex),
            ),
          );
          _applyOnlineCatalog(
            entries.map((entry) => entry.episode).toList(),
            '磁力任务',
          );
          if (requestedRssEpisodeIndex == null) {
            throw const RssException('所选视频文件不存在，请返回任务列表重新选择');
          }
          _catalogExpansionDone = Future.value();
          playbackStatus = '正在读取磁力任务';
          return true;
        }
        playbackStatus = '正在刷新字幕组订阅';
        final catalog = await resolver.load(
          bangumiItem.id,
          cancelToken: cancellation,
        );
        if (cancellation.isCancelled) return false;
        _rssCatalog = catalog;
        if (_requestedRssEpisode != null) {
          _requestedRssEpisode =
              catalog.episodeNumbers[_requestedRssEpisode] ??
              _requestedRssEpisode;
        }
        _applyOnlineCatalog(
          catalog.episodes,
          'RSS · ${catalog.subscription.group.name}',
        );
        _catalogExpansionDone =
            catalog.refreshed?.then((updated) {
              if (updated == null ||
                  cancellation.isCancelled ||
                  !isRssPlayback) {
                return;
              }
              final releases = {
                for (final release in catalog.releases) release.key: release,
                for (final release in updated.releases) release.key: release,
              };
              _rssCatalog = RssPlaybackCatalog(
                updated.subscription,
                releases.values.toList(),
                episodeNumbers: updated.episodeNumbers,
              );
              final known = apiEpisodes.map((episode) => episode.key).toSet();
              _applyOnlineCatalog([
                ...apiEpisodes,
                ...updated.episodes.where((episode) => known.add(episode.key)),
              ], 'RSS · ${updated.subscription.group.name}');
            }) ??
            Future.value();
        if (_requestedRssRelease != null && requestedRssEpisodeIndex == null) {
          await _catalogExpansionDone;
          if (cancellation.isCancelled) return false;
        }
        playbackStatus = 'RSS · ${catalog.subscription.group.name}';
        return true;
      }
      final catalog = await apiVideoService.loadCatalog(
        bangumiItem,
        cancelToken: cancellation,
      );
      if (cancellation.isCancelled) return false;
      runInAction(() {
        apiEpisodes = catalog.episodes;
        roadList = ObservableList.of([
          Road(
            name: apiPlaybackLibraryName,
            data: apiEpisodes
                .map((e) => apiEpisodePageUrl(bangumiItem.id, e))
                .toList(),
            identifier: apiEpisodes.map((e) => e.title).toList(),
          ),
        ]);
      });
      _log('已取得 ${catalog.episodes.length} 集，自动尝试可用资源');
      final expanded = Completer<void>();
      _catalogExpansionDone = expanded.future;
      void finishExpansion() {
        if (!expanded.isCompleted) expanded.complete();
      }

      unawaited(cancellation.whenCancel.then((_) => finishExpansion()));
      _catalogUpdates = apiVideoService
          .expandedEpisodes(bangumiItem, catalog, cancelToken: cancellation)
          .listen(
            (episodes) {
              if (cancellation.isCancelled) return;
              runInAction(() {
                apiEpisodes = episodes;
                roadList = ObservableList.of([
                  Road(
                    name: apiPlaybackLibraryName,
                    data: episodes
                        .map((e) => apiEpisodePageUrl(bangumiItem.id, e))
                        .toList(),
                    identifier: episodes.map((e) => e.title).toList(),
                  ),
                ]);
              });
            },
            onError: (Object error) {
              if (!cancellation.isCancelled) _log('备用资源剧集补齐失败，现有剧集仍可播放');
              finishExpansion();
            },
            onDone: finishExpansion,
            cancelOnError: true,
          );
      return true;
    } catch (error) {
      if (!cancellation.isCancelled) {
        if (isRssPlayback &&
            _directTorrentTaskId == null &&
            _requestedRssRelease == null &&
            GStorage.getSetting(SettingsKeys.rssFallbackToApi)) {
          playbackSource = 'api';
          playbackStatus = 'RSS 暂不可用，已切换为在线播放';
          _log(playbackStatus);
          return initializeOnline();
        }
        _failLoading(
          error is ApiVideoUnavailableException
              ? error.message
              : error is RssException
              ? error.message
              : '获取剧集失败，请重试',
        );
      }
      return false;
    }
  }

  void _applyOnlineCatalog(List<ApiVideoEpisode> episodes, String name) {
    runInAction(() {
      apiEpisodes = episodes;
      roadList = ObservableList.of([
        Road(
          name: name,
          data: episodes
              .map((e) => apiEpisodePageUrl(bangumiItem.id, e))
              .toList(),
          identifier: episodes.map((e) => e.title).toList(),
        ),
      ]);
    });
  }

  Future<void> switchPlaybackSource(
    String source,
    PlayerController player, {
    bool rememberSelection = true,
  }) async {
    if (isOfflineMode || (source != 'api' && source != 'rss')) return;
    if (rememberSelection) _rememberPlaybackSource(source);
    final old = selectedEpisode.episode;
    final key = old > 0 && old <= apiEpisodes.length
        ? apiEpisodes[old - 1].key
        : null;
    final offset = player.playback.currentPosition.inSeconds;
    _playbackSessions.cancel();
    _playbackCancellation?.cancel();
    unawaited(_torrentProgress?.cancel());
    _torrentProgress = null;
    _cancelMediaWatch();
    _catalogCancellation?.cancel();
    final session = beginOnlineStartup();
    final previous = _automaticPlayback;
    _automaticPlayback = null;
    final lease = _torrentLease;
    _torrentLease = null;
    await _cleanUpPlayback(() async => await previous?.cancel());
    if (session.isStale) {
      await _cleanUpPlayback(() async => await lease?.close());
      return;
    }
    await _cleanUpPlayback(() async => await lease?.close());
    await _cleanUpPlayback(player.stop);
    if (session.isStale) return;
    playbackSource = source;
    _requestedRssRelease = null;
    _requestedRssEpisode = null;
    _directTorrentTaskId = null;
    _requestedTorrentFile = null;
    _torrentFiles.clear();
    _rssCatalog = null;
    _rssRecovering = false;
    apiEpisodes = const [];
    roadList.clear();
    _beginEpisodeSwitch(selectedEpisode);
    if (!await initializeOnline() || session.isStale) return;
    var index = key == null ? 0 : apiEpisodes.indexWhere((e) => e.key == key);
    if (index < 0 && isRssPlayback) {
      await _catalogExpansionDone;
      if (session.isStale) return;
      index = apiEpisodes.indexWhere((e) => e.key == key);
    }
    if (index < 0 &&
        isRssPlayback &&
        GStorage.getSetting(SettingsKeys.rssFallbackToApi)) {
      playbackSource = 'api';
      playbackStatus = '订阅尚未发布这一话，已切换为在线播放';
      if (!await initializeOnline() || session.isStale) return;
      index = apiEpisodes.indexWhere((e) => e.key == key);
    }
    if (index < 0) {
      await _catalogExpansionDone;
      if (session.isStale) return;
      index = apiEpisodes.indexWhere((e) => e.key == key);
    }
    if (index < 0) {
      resetEpisodeState(episode: 0);
      _failLoading('当前播放方式没有对应集数，请选择下方其他剧集');
      return;
    }
    await changeEpisode(index + 1, offset: offset, playerController: player);
  }

  Future<void> _cleanUpPlayback(Future<void> Function() cleanup) async {
    try {
      await cleanup();
    } catch (error) {
      KazumiLogger().w('Playback cleanup failed', error: error);
    }
  }

  void _rememberPlaybackSource(String source) {
    unawaited(
      playbackPreferences.remember(bangumiItem.id, source).catchError((
        Object error,
      ) {
        KazumiLogger().w(
          'Failed to save playback source preference',
          error: error,
        );
      }),
    );
  }

  Future<int?> restoreOnlineEpisode({
    String? pageUrl,
    int? legacyEpisode,
    AsyncSession? startupSession,
  }) async {
    if (startupSession?.isStale == true) return null;
    if (pageUrl != null && pageUrl.startsWith('monogatari://episode/')) {
      var targetPageUrl = canonicalEpisodePageUrl(pageUrl);
      final oldNumber = double.tryParse(Uri.parse(pageUrl).pathSegments.last);
      if (isRssPlayback &&
          oldNumber != null &&
          !apiEpisodes.any((episode) => episode.number == oldNumber)) {
        final corrected = _rssCatalog?.episodeNumbers[oldNumber];
        if (corrected != null)
          targetPageUrl =
              'monogatari://episode/${bangumiItem.id}/${rssEpisodeKey(corrected)}';
      }
      int find() => apiEpisodes.indexWhere(
        (episode) =>
            apiEpisodePageUrl(bangumiItem.id, episode) == targetPageUrl,
      );
      var index = find();
      if (index < 0 && isRssPlayback) {
        await _catalogExpansionDone;
        if (startupSession?.isStale == true) return null;
        index = find();
      }
      if (index < 0 &&
          isRssPlayback &&
          _requestedRssRelease == null &&
          GStorage.getSetting(SettingsKeys.rssFallbackToApi)) {
        playbackSource = 'api';
        if (!await initializeOnline() || startupSession?.isStale == true) {
          return null;
        }
        index = find();
      }
      if (index < 0) {
        await _catalogExpansionDone;
        if (startupSession?.isStale == true) return null;
        index = find();
      }
      if (index < 0) {
        _failLoading('上次观看的剧集暂时没有可用资源，请选择其他集数');
        return null;
      }
      return index + 1;
    }
    final episode = legacyEpisode ?? 1;
    return episode > 0 && episode <= apiEpisodes.length ? episode : 1;
  }

  /// The list position of episode [number] (第 N 话), waiting for the full
  /// catalog when it is not among the first episodes loaded.
  Future<int?> onlineEpisodeByNumber(
    int number, {
    AsyncSession? startupSession,
  }) async {
    if (startupSession?.isStale == true) return null;
    int find() => apiEpisodes.indexWhere((episode) => episode.number == number);
    var index = find();
    if (index < 0 && isRssPlayback) {
      await _catalogExpansionDone;
      if (startupSession?.isStale == true) return null;
      index = find();
    }
    if (index < 0 &&
        isRssPlayback &&
        _requestedRssRelease == null &&
        GStorage.getSetting(SettingsKeys.rssFallbackToApi)) {
      playbackSource = 'api';
      if (!await initializeOnline() || startupSession?.isStale == true) {
        return null;
      }
      index = find();
    }
    if (index < 0) {
      await _catalogExpansionDone;
      if (startupSession?.isStale == true) return null;
      index = find();
    }
    if (index < 0) {
      _failLoading('第 $number 话暂时没有可用资源，请选择其他集数');
      return null;
    }
    return index + 1;
  }

  int? adjacentOnlineEpisode(int episode, {required bool forward}) {
    if (episode <= 0 || episode > apiEpisodes.length) return null;
    if (isRssPlayback && apiEpisodes[episode - 1].number == null) return null;
    final ordered =
        [
          ...apiEpisodes.where(
            (entry) => !isRssPlayback || entry.number != null,
          ),
        ]..sort((a, b) {
          if (a.number != null && b.number != null) {
            return a.number!.compareTo(b.number!);
          }
          if (a.number != null) return -1;
          if (b.number != null) return 1;
          return a.key.compareTo(b.key);
        });
    final index =
        ordered.indexOf(apiEpisodes[episode - 1]) + (forward ? 1 : -1);
    if (index < 0 || index >= ordered.length) return null;
    return apiEpisodes.indexOf(ordered[index]) + 1;
  }

  Future<void> retryPlayback(PlayerController playerController) async {
    apiVideoService.clearCache();
    await changeEpisode(
      selectedEpisode.episode > 0 ? selectedEpisode.episode : 1,
      currentRoad: selectedEpisode.road,
      offset: playerController.playback.currentPosition.inSeconds,
      playerController: playerController,
    );
  }

  void _log(String message) {
    KazumiLogger().i('AutomaticPlayback: $message');
    if (!_logStreamController.isClosed) _logStreamController.add(message);
  }

  @action
  void _initForOfflinePlayback({
    required BangumiItem bangumiItem,
    required String pluginName,
    required int episodeNumber,
    required int road,
    required List<DownloadEpisode> downloadedEpisodes,
  }) {
    this.bangumiItem = bangumiItem;
    _offlinePluginName = pluginName;
    title = bangumiItem.nameCn.isNotEmpty
        ? bangumiItem.nameCn
        : bangumiItem.name;
    isOfflineMode = true;
    _loading = false;

    _buildOfflineRoadList(downloadedEpisodes);

    final target = _findOfflineEpisodeByNumber(
      episodeNumber,
      preferredOriginalRoad: road,
    );
    final selected = VideoEpisodeSelection(
      episode: target?.listIndex ?? 1,
      road: target?.roadIndex ?? 0,
    );
    selectedEpisode = selected;
    playingEpisode = null;
    commentsEpisode = commentEpisodeForSelection(selected);
    final resolvedEpisode = _resolveOfflineEpisode(
      selected.episode,
      road: selected.road,
    );
    if (resolvedEpisode != null) {
      _setOfflineHistoryIdentity(resolvedEpisode);
    } else {
      _playbackHistoryIdentity = null;
    }
    KazumiLogger().i(
      'VideoPageController: initialized for offline playback, episode $episodeNumber (position: ${selected.episode})',
    );
  }

  void _buildOfflineRoadList(List<DownloadEpisode> episodes) {
    final snapshot = buildOfflineRoadListSnapshot(episodes);
    roadList.clear();
    roadList.addAll(snapshot.roads);
    _offlineEpisodesByNumber.clear();
    _offlineEpisodesByNumber.addAll(snapshot.episodesByNumber);
    _offlineDisplayRoadToOriginalRoad.clear();
    _offlineDisplayRoadToOriginalRoad.addAll(
      snapshot.displayRoadToOriginalRoad,
    );
    _offlineOriginalRoadToDisplayRoad.clear();
    _offlineOriginalRoadToDisplayRoad.addAll(
      snapshot.originalRoadToDisplayRoad,
    );
  }

  String get offlinePluginName => _offlinePluginName;

  PlaybackHistoryIdentity? get currentHistoryIdentity =>
      _playbackHistoryIdentity;

  ({int listIndex, int roadIndex})? _findOfflineEpisodeByNumber(
    int episodeNumber, {
    required int preferredOriginalRoad,
  }) {
    if (episodeNumber <= 0 || roadList.isEmpty) {
      return null;
    }
    final preferredDisplayRoad =
        _offlineOriginalRoadToDisplayRoad[preferredOriginalRoad];
    final roadIndices = <int>[
      if (preferredDisplayRoad != null) preferredDisplayRoad,
      for (var i = 0; i < roadList.length; i++)
        if (i != preferredDisplayRoad) i,
    ];
    for (final roadIndex in roadIndices) {
      final match = _findOfflineEpisodeInDisplayRoad(episodeNumber, roadIndex);
      if (match != null) {
        return match;
      }
    }
    return null;
  }

  ({int listIndex, int roadIndex})? _findOfflineEpisodeInDisplayRoad(
    int episodeNumber,
    int roadIndex,
  ) {
    if (roadIndex < 0 || roadIndex >= roadList.length) {
      return null;
    }
    final index = roadList[roadIndex].data.indexOf(episodeNumber.toString());
    if (index < 0) {
      return null;
    }
    return (listIndex: index + 1, roadIndex: roadIndex);
  }

  int getHistoryOffsetFor(PlaybackHistoryIdentity identity) {
    final playResume = GStorage.getSetting(SettingsKeys.playResume);
    if (playResume != true) {
      return 0;
    }
    if (identity.entryKind == HistoryEntryKind.online &&
        identity.episodePageUrl.startsWith('monogatari://episode/')) {
      final history = historyController.historyForSubject(
        identity.bangumiItem,
        identity.pluginName,
      );
      if (history == null) return 0;
      for (final progress in history.progresses.values) {
        if (canonicalEpisodePageUrl(progress.episodePageUrl) ==
                canonicalEpisodePageUrl(identity.episodePageUrl) ||
            identity.legacyEpisodePageUrls.contains(progress.episodePageUrl)) {
          return progress.progress.inSeconds;
        }
      }
      return history.episodePageUrl == identity.episodePageUrl
          ? history.progresses[history.lastWatchEpisode]?.progress.inSeconds ??
                0
          : 0;
    }
    return historyController
            .findProgress(
              identity.bangumiItem,
              identity.pluginName,
              identity.episodeNumber,
              entryKind: identity.entryKind,
            )
            ?.progress
            .inSeconds ??
        0;
  }

  void _setOnlineHistoryIdentity(EpisodeRef episode) {
    _playbackHistoryIdentity = PlaybackHistoryIdentity.online(
      bangumiItem: bangumiItem,
      pluginName: apiPlaybackLibraryName,
      episodeNumber: episode.historyEpisodeNumber,
      episodeTitle: episode.displayTitle,
      road: episode.originalRoadIndex,
      onlineBangumiSrc: src,
      episodePageUrl: episode.pageUrl,
      legacyEpisodePageUrls: _legacyRssPageUrls(episode.pageUrl),
    );
  }

  List<String> _legacyRssPageUrls(String pageUrl) {
    if (!isRssPlayback || _rssCatalog == null) return const [];
    final number = double.tryParse(Uri.parse(pageUrl).pathSegments.last);
    return [
      for (final entry in _rssCatalog!.episodeNumbers.entries)
        if (entry.value == number &&
            entry.key != number &&
            !apiEpisodes.any((episode) => episode.number == entry.key))
          'monogatari://episode/${bangumiItem.id}/${rssEpisodeKey(entry.key)}',
    ];
  }

  void _setOfflineHistoryIdentity(EpisodeRef episode) {
    _playbackHistoryIdentity = PlaybackHistoryIdentity.offline(
      bangumiItem: bangumiItem,
      pluginName: _offlinePluginName,
      episodeNumber: episode.historyEpisodeNumber,
      episodeTitle: episode.displayTitle,
      road: episode.originalRoadIndex,
      episodePageUrl: episode.pageUrl,
    );
  }

  EpisodeRef? _resolveOnlineEpisode(int episode, {int? road}) {
    final targetRoad = road ?? selectedEpisode.road;
    if (roadList.isEmpty || targetRoad < 0 || targetRoad >= roadList.length) {
      return null;
    }
    final roadData = roadList[targetRoad];
    final index = episode - 1;
    if (index < 0 ||
        index >= roadData.data.length ||
        index >= roadData.identifier.length) {
      return null;
    }
    final displayTitle = roadData.identifier[index];
    return EpisodeRef.online(
      listIndex: episode,
      roadIndex: targetRoad,
      displayTitle: displayTitle,
      pageUrl: roadData.data[index],
      contentEpisodeNumber:
          apiEpisodes[index].number?.isFinite == true &&
              apiEpisodes[index].number! > 0 &&
              apiEpisodes[index].number ==
                  apiEpisodes[index].number!.truncateToDouble()
          ? apiEpisodes[index].number!.toInt()
          : 0,
    );
  }

  EpisodeRef? _resolveOfflineEpisode(int episode, {int? road}) {
    final targetRoad = road ?? selectedEpisode.road;
    if (roadList.isEmpty || targetRoad < 0 || targetRoad >= roadList.length) {
      return null;
    }
    final roadData = roadList[targetRoad];
    final index = episode - 1;
    if (index < 0 ||
        index >= roadData.data.length ||
        index >= roadData.identifier.length) {
      return null;
    }
    final episodeNumber = int.tryParse(roadData.data[index]);
    if (episodeNumber == null) {
      return null;
    }
    final downloadEpisode = _offlineEpisodesByNumber[episodeNumber];
    final titleFromRoad = roadData.identifier[index];
    final episodeTitle = downloadEpisode?.episodeName.isNotEmpty == true
        ? downloadEpisode!.episodeName
        : (titleFromRoad.isNotEmpty ? titleFromRoad : '第$episodeNumber集');
    return EpisodeRef.offline(
      listIndex: episode,
      roadIndex: targetRoad,
      displayTitle: episodeTitle,
      pageUrl: downloadEpisode?.episodePageUrl ?? '',
      episodeNumber: episodeNumber,
      originalRoadIndex:
          downloadEpisode?.road ??
          _offlineDisplayRoadToOriginalRoad[targetRoad] ??
          targetRoad,
      contentEpisodeNumber: downloadEpisode?.apiEpisodeKey.isNotEmpty == true
          ? downloadEpisode!.danmakuQueryEpisodeNumber ?? 0
          : null,
    );
  }

  EpisodeRef? resolveEpisode(VideoEpisodeSelection selection) {
    return isOfflineMode
        ? _resolveOfflineEpisode(selection.episode, road: selection.road)
        : _resolveOnlineEpisode(selection.episode, road: selection.road);
  }

  int commentEpisodeForSelection(VideoEpisodeSelection selection) {
    final resolvedEpisode = resolveEpisode(selection);
    return resolvedEpisode?.danmakuEpisodeNumber ?? selection.episode;
  }

  /// Resets pre-switch state as a single transaction so observers see one
  /// notification instead of one per field.
  @action
  void _beginEpisodeSwitch(VideoEpisodeSelection selection) {
    final targetCommentsEpisode = commentEpisodeForSelection(selection);
    selectedEpisode = selection;
    playingEpisode = null;
    // The comments sheet only re-queries when [commentsEpisode] changes, so
    // resetting comment state here without changing it would blank the sheet
    // permanently.
    if (targetCommentsEpisode != commentsEpisode) {
      commentsEpisode = targetCommentsEpisode;
      _resetEpisodeComments();
    }
    _loading = true;
    _errorMessage = null;
  }

  @action
  void _applyResolvedSelection(EpisodeRef resolvedEpisode) {
    selectedEpisode = VideoEpisodeSelection(
      episode: resolvedEpisode.listIndex,
      road: resolvedEpisode.roadIndex,
    );
    commentsEpisode = commentEpisodeForSelection(selectedEpisode);
  }

  @action
  void _finishLoading() {
    _loading = false;
  }

  @action
  void _failLoading(String message) {
    _loading = false;
    _errorMessage = message;
  }

  Future<void> changeEpisode(
    int episode, {
    int currentRoad = 0,
    int offset = 0,
    bool resumeHistory = true,
    required PlayerController playerController,
  }) async {
    _onlineStartupSessions.cancel();
    final session = _playbackSessions.begin();
    final selection = VideoEpisodeSelection(
      episode: episode,
      road: currentRoad,
    );
    _beginEpisodeSwitch(selection);
    _danmakuSessions.cancel();
    playerController.danmaku.finishDanmakuLoad();
    _playbackCancellation?.cancel();
    unawaited(_torrentProgress?.cancel());
    _torrentProgress = null;
    _cancelMediaWatch();
    final previousPlayback = _automaticPlayback;
    _automaticPlayback = null;
    final previousLease = _torrentLease;
    _torrentLease = null;
    _rssRecovering = false;
    await _cleanUpPlayback(() async => await previousPlayback?.cancel());
    await _cleanUpPlayback(() async => await previousLease?.close());
    if (session.isStale) return;
    _activePlayerController = playerController;
    playerController.onPlaybackError = null;

    try {
      await playerController.stop();
    } catch (error) {
      KazumiLogger().w(
        'VideoPageController: playback cleanup failed',
        error: error,
      );
    }
    if (session.isStale) {
      return;
    }

    if (isOfflineMode) {
      await _changeOfflineEpisode(
        selection,
        offset,
        session: session,
        playerController: playerController,
      );
      return;
    }

    if (apiEpisodes.isEmpty && !await initializeOnline()) return;
    if (session.isStale) return;

    final resolvedEpisode = _resolveOnlineEpisode(episode, road: currentRoad);
    if (resolvedEpisode == null) {
      KazumiLogger().e(
        'VideoPageController: failed to resolve online episode. road=$currentRoad, episode=$episode',
      );
      _failLoading('集数解析失败');
      return;
    }

    _applyResolvedSelection(resolvedEpisode);
    _setOnlineHistoryIdentity(resolvedEpisode);
    final resolvedOffset = resumeHistory && offset <= 0
        ? getHistoryOffsetFor(_playbackHistoryIdentity!)
        : offset;

    KazumiLogger().i(
      'VideoPageController: changed to ${resolvedEpisode.displayTitle}',
    );
    if (isRssPlayback) {
      await _startRssPlayback(
        resolvedOffset,
        resolvedEpisode: resolvedEpisode,
        session: session,
        playerController: playerController,
      );
      return;
    }
    await _startAutomaticPlayback(
      resolvedOffset,
      resolvedEpisode: resolvedEpisode,
      session: session,
      playerController: playerController,
    );
  }

  Future<void> _changeOfflineEpisode(
    VideoEpisodeSelection selection,
    int offset, {
    required AsyncSession session,
    required PlayerController playerController,
  }) async {
    final resolvedEpisode = _resolveOfflineEpisode(
      selection.episode,
      road: selection.road,
    );
    if (resolvedEpisode == null) {
      KazumiLogger().e(
        'VideoPageController: failed to resolve offline episode. road=${selection.road}, episode=${selection.episode}',
      );
      _failLoading('集数解析失败');
      return;
    }

    final localPath = _getLocalVideoPath(
      bangumiItem.id,
      _offlinePluginName,
      resolvedEpisode.historyEpisodeNumber,
    );
    if (localPath == null) {
      _failLoading('该集数未下载');
      return;
    }
    _applyResolvedSelection(resolvedEpisode);
    _setOfflineHistoryIdentity(resolvedEpisode);
    if (session.isStale) {
      return;
    }
    _finishLoading();
    final resolvedOffset = offset > 0
        ? offset
        : getHistoryOffsetFor(_playbackHistoryIdentity!);

    KazumiLogger().i(
      'VideoPageController: offline episode changed to ${resolvedEpisode.historyEpisodeNumber} (index: ${selection.episode}), path: $localPath',
    );

    final params = PlaybackInitParams(
      videoUrl: localPath,
      offset: resolvedOffset,
      isLocalPlayback: true,
      bangumiId: bangumiItem.id,
      pluginName: _offlinePluginName,
      episode: resolvedEpisode.listIndex,
      danmakuEpisodeNumber: resolvedEpisode.danmakuEpisodeNumber,
      pageUrl: resolvedEpisode.pageUrl,
      sortNumber: resolvedEpisode.sortNumber,
      httpHeaders: {},
      adBlockerEnabled: false,
      episodeTitle: resolvedEpisode.displayTitle,
      referer: '',
      currentRoad: resolvedEpisode.roadIndex,
      coverUrl: bangumiItem.images['large'],
      bangumiName: bangumiItem.nameCn.isNotEmpty
          ? bangumiItem.nameCn
          : bangumiItem.name,
    );

    final initialized = await playerController.init(params);
    if (session.isActive && initialized) {
      playingEpisode = selection;
      unawaited(_loadPlaybackDanmaku(playerController, params, session));
    } else if (session.isActive) {
      _playbackSessions.cancel();
    }
  }

  Future<void> _loadPlaybackDanmaku(
    PlayerController playerController,
    PlaybackInitParams params,
    AsyncSession session,
  ) async {
    if (params.danmakuEpisodeNumber <= 0) {
      playerController.danmaku.finishDanmakuLoad(disableDanmaku: true);
      return;
    }
    final danmakuSession = _danmakuSessions.begin();
    playerController.danmaku.beginDanmakuLoad();
    try {
      final result = await playerController.danmaku.fetchDanmaku(
        params.bangumiId,
        params.pluginName,
        params.danmakuEpisodeNumber,
        cacheEpisode: params.isLocalPlayback
            ? _playbackHistoryIdentity?.episodeNumber
            : null,
      );
      if (session.isActive && danmakuSession.isActive) {
        if (result.hasDanmakus) {
          final bool enableDanmaku = GStorage.getSetting(
            SettingsKeys.danmakuEnabledByDefault,
          );
          playerController.danmaku.applyDanmakuLoad(
            result,
            enableDanmaku: enableDanmaku,
          );
        } else {
          playerController.danmaku.applyUnavailableDanmakuLoad(result);
          if (result.isFailed) {
            KazumiDialog.showToast(message: '弹幕加载失败，可手动检索');
          }
        }
      }
    } catch (e) {
      if (session.isActive && danmakuSession.isActive) {
        playerController.danmaku.finishDanmakuLoad(disableDanmaku: true);
        KazumiDialog.showToast(message: '弹幕加载失败，可手动检索');
      }
      KazumiLogger().w('VideoPageController: failed to load danmaku', error: e);
    }
  }

  void cancelAutomaticDanmakuLoad() {
    _danmakuSessions.cancel();
  }

  String? _getLocalVideoPath(
    int bangumiId,
    String pluginName,
    int episodeNumber,
  ) {
    final episode = downloadRepository.getEpisode(
      bangumiId,
      pluginName,
      episodeNumber,
    );
    return downloadManager.getLocalVideoPath(episode);
  }

  Future<void> _startAutomaticPlayback(
    int offset, {
    required EpisodeRef resolvedEpisode,
    required AsyncSession session,
    required PlayerController playerController,
  }) async {
    final cancellation = CancelToken();
    _playbackCancellation = cancellation;
    PlaybackInitParams? activeParams;
    String? lastFailure;
    final runner = AutomaticPlaybackRunner<ApiVideoCandidate>(
      onFailure: (error) {
        if (error is ApiVideoUnavailableException) lastFailure = error.message;
        if (error is FormatException) lastFailure = error.message;
      },
      currentOffset: () => playerController.playback.currentPosition.inSeconds,
      stop: () async {
        _cancelMediaWatch();
        playerController.onPlaybackError = null;
        await playerController.stop();
      },
      onAttempt: (candidate) {
        if (session.isStale) return;
        _beginEpisodeSwitch(selectedEpisode);
        _log('正在尝试 ${candidate.provider.name} · ${candidate.episode.title}');
      },
      open: (candidate, resumeOffset) async {
        if (session.isStale) return false;
        final params = PlaybackInitParams(
          videoUrl: candidate.url,
          offset: resumeOffset,
          isLocalPlayback: false,
          videoSourceFormat: candidate.format,
          publicNetworkOnly: true,
          bangumiId: bangumiItem.id,
          pluginName: apiPlaybackLibraryName,
          episode: resolvedEpisode.listIndex,
          danmakuEpisodeNumber: resolvedEpisode.danmakuEpisodeNumber,
          pageUrl: resolvedEpisode.pageUrl,
          sortNumber: resolvedEpisode.sortNumber,
          httpHeaders: candidate.httpHeaders,
          adBlockerEnabled:
              candidate.adBlocker ||
              GStorage.getSetting(SettingsKeys.forceAdBlocker),
          episodeTitle: resolvedEpisode.displayTitle,
          referer:
              candidate.httpHeaders['Referer'] ??
              candidate.httpHeaders['referer'] ??
              '',
          currentRoad: 0,
          coverUrl: bangumiItem.images['large'],
          bangumiName: title,
        );
        activeParams = params;
        final playable = await _openAndWatchMedia(
          playerController,
          params,
          session,
        );
        if (!playable) lastFailure = '视频连接或解码失败，已尝试备用片源，请重试';
        return playable;
      },
      onReady: (candidate) {
        if (session.isStale) return;
        playingEpisode = selectedEpisode;
        _finishLoading();
        _log('正在播放 ${candidate.provider.name} · ${candidate.episode.title}');
        unawaited(
          _loadPlaybackDanmaku(playerController, activeParams!, session),
        );
      },
      onExhausted: () {
        if (session.isStale) return;
        _cancelMediaWatch();
        playerController.onPlaybackError = null;
        unawaited(playerController.stop());
        _failLoading(lastFailure ?? '已自动尝试全部播放资源，暂时无法播放，请稍后重试');
      },
    );
    _automaticPlayback = runner;
    await runner.start(
      apiVideoService.candidatesForEpisode(
        bangumiItem,
        apiEpisodes[resolvedEpisode.listIndex - 1],
        cancelToken: cancellation,
      ),
      offset: offset,
    );
  }

  Future<void> _startRssPlayback(
    int offset, {
    required EpisodeRef resolvedEpisode,
    required AsyncSession session,
    required PlayerController playerController,
  }) async {
    final cancellation = CancelToken();
    _playbackCancellation = cancellation;
    try {
      final catalog = _rssCatalog;
      final resolver = rssPlayback;
      if ((catalog == null && _directTorrentTaskId == null) ||
          resolver == null) {
        throw const RssException('请重新加载订阅');
      }
      final episode = apiEpisodes[resolvedEpisode.listIndex - 1];
      final explicitId = requestedRssEpisodeIndex == resolvedEpisode.listIndex
          ? _requestedRssRelease
          : null;
      final retainDownload = GStorage.getSetting(
        SettingsKeys.rssDownloadWhilePlaying,
      );
      final lease = _directTorrentTaskId != null
          ? await resolver.torrents.openStream(
              _directTorrentTaskId!,
              _torrentFiles[episode.key]!,
              cancelToken: cancellation,
              downloadWhilePlaying: retainDownload,
            )
          : await resolver.open(
              catalog!,
              episode,
              releaseId: explicitId,
              downloadWhilePlaying: retainDownload,
              cancelToken: cancellation,
              onStatus: (status) {
                if (session.isActive) playbackStatus = status;
              },
            );
      if (session.isStale) {
        await lease.close();
        return;
      }
      final replacedLease = _torrentLease;
      _torrentLease = lease;
      if (replacedLease != null && !identical(replacedLease, lease)) {
        await _cleanUpPlayback(replacedLease.close);
      }
      TorrentTaskSnapshot? latestTask;
      void updateProgress(List<TorrentTaskSnapshot> tasks) {
        if (session.isStale || !_loading || _automaticPlayback != null) return;
        for (final task in tasks) {
          if (task.id != lease.taskId) continue;
          latestTask = task;
          playbackStatus = rssBufferingStatus(task);
        }
      }

      updateProgress(resolver.torrents.tasks);
      _torrentProgress = resolver.torrents.watchTasks.listen(updateProgress);
      final params = PlaybackInitParams(
        videoUrl: lease.url.toString(),
        offset: offset,
        isLocalPlayback: false,
        isTorrentStream: true,
        bangumiId: bangumiItem.id,
        pluginName: apiPlaybackLibraryName,
        episode: resolvedEpisode.listIndex,
        danmakuEpisodeNumber: resolvedEpisode.danmakuEpisodeNumber,
        pageUrl: resolvedEpisode.pageUrl,
        sortNumber: resolvedEpisode.sortNumber,
        httpHeaders: const {},
        adBlockerEnabled: false,
        episodeTitle: resolvedEpisode.displayTitle,
        referer: '',
        currentRoad: 0,
        coverUrl: bangumiItem.images['large'],
        bangumiName: title,
      );
      final playable = await _openAndWatchMedia(
        playerController,
        params,
        session,
      );
      if (session.isStale) return;
      if (!playable) throw RssException(rssStartupFailure(latestTask));
      // A successful reopening ends this recovery burst. A later listener
      // failure can be repaired again instead of being blocked for the episode.
      _rssEndpointRecovery = null;
      playingEpisode = selectedEpisode;
      playbackStatus = catalog == null
          ? '正在播放磁力文件'
          : 'RSS · ${catalog.subscription.group.name}';
      _finishLoading();
      if (episode.number != null &&
          episode.number! == episode.number!.truncateToDouble()) {
        unawaited(_loadPlaybackDanmaku(playerController, params, session));
      }
    } catch (error) {
      if (session.isStale || cancellation.isCancelled) return;
      await _handleRssFailure(
        error.toString(),
        offset,
        resolvedEpisode,
        session,
        playerController,
      );
    }
  }

  Future<void> _handleRssFailure(
    String message,
    int offset,
    EpisodeRef episode,
    AsyncSession session,
    PlayerController player,
  ) async {
    if (_rssRecovering || session.isStale) return;
    _rssRecovering = true;
    unawaited(_torrentProgress?.cancel());
    _torrentProgress = null;
    _cancelMediaWatch();
    player.onPlaybackError = null;
    final lease = _torrentLease;
    if (lease != null && !identical(_rssEndpointRecovery, session)) {
      var replaced = false;
      try {
        replaced = await rssPlayback!.torrents.ensurePlaybackServer(
          checkConnection: true,
        );
      } catch (_) {}
      if (replaced && session.isActive) {
        _rssEndpointRecovery = session;
        _log('本地播放连接已恢复，正在继续播放');
        await _cleanUpPlayback(player.stop);
        if (session.isStale) return;
        _rssRecovering = false;
        await _startRssPlayback(
          offset,
          resolvedEpisode: episode,
          session: session,
          playerController: player,
        );
        return;
      }
    }
    _torrentLease = null;
    _log('RSS 播放失败：$message');
    // Cancel pending piece reads before native disposal, which may itself wait
    // for its HTTP reader to stop. Otherwise failure recovery can keep waiting.
    await _cleanUpPlayback(() async => await lease?.close());
    await _cleanUpPlayback(player.stop);
    if (session.isStale) return;
    final number = apiEpisodes[episode.listIndex - 1].number;
    if (number != null && GStorage.getSetting(SettingsKeys.rssFallbackToApi)) {
      playbackStatus = 'RSS 暂不可用，正在尝试在线播放';
      _log(playbackStatus);
      await _startAutomaticPlayback(
        offset,
        resolvedEpisode: episode,
        session: session,
        playerController: player,
      );
    } else {
      _failLoading(message);
    }
  }

  Timer? _qualityTimer;
  AsyncSession? _rssEndpointRecovery;

  Future<bool> _openAndWatchMedia(
    PlayerController controller,
    PlaybackInitParams params,
    AsyncSession session,
  ) async {
    final ready = Completer<bool>();
    _pendingOpen = ready;
    void complete(bool value) {
      if (!ready.isCompleted) ready.complete(value);
    }

    controller.onPlaybackError = (error) {
      if (session.isStale ||
          !AutomaticPlaybackRunner.isFatalMediaError(error)) {
        return false;
      }
      _log('当前资源播放失败，自动尝试下一个');
      if (!ready.isCompleted) {
        complete(false);
      } else {
        _recoverPlayback(session);
      }
      return true;
    };
    final startupTimer = Timer(
      Duration(seconds: params.isTorrentStream ? 90 : 18),
      () {
        _log('当前资源加载超时，自动尝试下一个');
        complete(false);
      },
    );
    _startupTimer = startupTimer;
    try {
      final initialized = await waitForMediaInitialization(
        initialization: controller.init(params),
        interrupted: ready.future,
        isCurrent: () => session.isActive,
      );
      if (!initialized || session.isStale) complete(false);
      final player = controller.playback.mediaPlayer;
      if (player == null || ready.isCompleted) return await ready.future;
      final videoController = controller.playback.videoController;
      if (videoController == null) {
        complete(false);
        return false;
      }
      bool current() =>
          session.isActive && controller.playback.isCurrentPlayer(player);

      void watchBuffering(bool buffering) {
        if (!current()) {
          complete(false);
          return;
        }
        if (ready.isCompleted && buffering && player.state.playing) {
          // Native backends may repeat buffering/playing events while stalled.
          // Keep the deadline for this continuous stall instead of restarting it.
          _bufferingTimer ??= Timer(
            Duration(seconds: params.isTorrentStream ? 90 : 25),
            () {
              if (current() && player.state.buffering && player.state.playing) {
                _log('当前资源长时间缓冲，自动尝试下一个');
                _recoverPlayback(session);
              }
            },
          );
        } else {
          _bufferingTimer?.cancel();
          _bufferingTimer = null;
        }
      }

      _mediaSubscriptions.addAll([
        player.stream.buffering.listen(watchBuffering),
        player.stream.playing.listen(
          (_) => watchBuffering(player.state.buffering),
        ),
      ]);
      final playable = await waitForFirstVideoFrame(
        firstFrame: videoController.waitUntilFirstFrameRendered,
        interrupted: ready.future,
        isCurrent: current,
      );
      complete(playable);
      watchBuffering(player.state.buffering);
      if (playable && !params.isTorrentStream) {
        final quality = PlaybackStallMonitor();
        _qualityTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!current()) return;
          quality.update(
            playing: player.state.playing,
            buffering: player.state.buffering,
          );
          if (quality.shouldRecover) {
            _log('当前片源频繁缓冲，保持进度尝试备用资源');
            _recoverPlayback(session);
          }
        });
      }
      if (!playable) {
        _log('当前资源不可用，继续自动尝试');
      }
      return playable && current();
    } catch (error) {
      _log('当前资源初始化失败，继续自动尝试');
      complete(false);
      return false;
    } finally {
      startupTimer.cancel();
      if (identical(_startupTimer, startupTimer)) _startupTimer = null;
      if (identical(_pendingOpen, ready)) _pendingOpen = null;
    }
  }

  void _recoverPlayback(AsyncSession session) {
    // Defer until the open/ready continuation settles, so an error arriving
    // immediately after the first decoded frame cannot lose its recovery.
    Timer.run(() {
      if (session.isStale) return;
      if (_automaticPlayback == null && isRssPlayback) {
        final episode = _resolveOnlineEpisode(selectedEpisode.episode);
        final player = _activePlayerController;
        if (episode != null && player != null) {
          unawaited(
            _handleRssFailure(
              'RSS 视频连接中断，请重试',
              player.playback.currentPosition.inSeconds,
              episode,
              session,
              player,
            ),
          );
        }
        return;
      }
      unawaited(_automaticPlayback?.recover());
    });
  }

  void _cancelMediaWatch() {
    _qualityTimer?.cancel();
    _qualityTimer = null;
    _startupTimer?.cancel();
    _startupTimer = null;
    _bufferingTimer?.cancel();
    _bufferingTimer = null;
    final pending = _pendingOpen;
    _pendingOpen = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
    for (final subscription in _mediaSubscriptions) {
      unawaited(subscription.cancel());
    }
    _mediaSubscriptions.clear();
  }

  void _resetEpisodeComments() {
    _commentSessions.cancel();
    episodeInfo.reset();
    episodeCommentsList.clear();
  }

  Future<bool> queryBangumiEpisodeCommentsByID(int id, int episode) async {
    final session = _commentSessions.begin();
    final EpisodeInfo latestEpisodeInfo;
    try {
      latestEpisodeInfo = await BangumiApi.getBangumiEpisodeByID(id, episode);
    } catch (_) {
      if (session.isStale) {
        return false;
      }
      rethrow;
    }
    if (session.isStale) {
      return false;
    }
    final EpisodeCommentResponse value;
    try {
      value = await BangumiApi.getBangumiCommentsByEpisodeID(
        latestEpisodeInfo.id,
      );
    } catch (_) {
      if (session.isStale) {
        return false;
      }
      rethrow;
    }
    if (session.isStale) {
      return false;
    }
    final commentsList = value.commentList;
    if (!isCommentsAscending) {
      commentsList.sort(
        (a, b) => b.comment.createdAt.compareTo(a.comment.createdAt),
      );
    } else {
      commentsList.sort(
        (a, b) => a.comment.createdAt.compareTo(b.comment.createdAt),
      );
    }
    _applyEpisodeComments(episode, latestEpisodeInfo, commentsList);
    KazumiLogger().i(
      'VideoPageController: loaded comments list length ${episodeCommentsList.length}',
    );
    return true;
  }

  @action
  void _applyEpisodeComments(
    int episode,
    EpisodeInfo info,
    List<EpisodeCommentItem> comments,
  ) {
    commentsEpisode = episode;
    episodeInfo = info;
    episodeCommentsList = ObservableList.of(comments);
  }

  @action
  void toggleSortOrder() {
    isCommentsAscending = !isCommentsAscending;
    episodeCommentsList.sort(
      (a, b) => isCommentsAscending
          ? a.comment.createdAt.compareTo(b.comment.createdAt)
          : b.comment.createdAt.compareTo(a.comment.createdAt),
    );
  }

  /// Called by Modular when the '/video' route scope is disposed.
  @override
  void dispose() {
    _onlineStartupSessions.close();
    unawaited(fullscreen.close());
    _playbackSessions.cancel();
    _danmakuSessions.cancel();
    _commentSessions.cancel();
    _catalogCancellation?.cancel();
    unawaited(_catalogUpdates?.cancel());
    _playbackCancellation?.cancel();
    _cancelMediaWatch();
    _activePlayerController?.onPlaybackError = null;
    unawaited(_automaticPlayback?.cancel());
    unawaited(_torrentProgress?.cancel());
    final lease = _torrentLease;
    _torrentLease = null;
    unawaited(_cleanUpPlayback(() async => await lease?.close()));
    if (!_logStreamController.isClosed) {
      _logStreamController.close();
    }
  }
}

class OfflineRoadListSnapshot {
  const OfflineRoadListSnapshot({
    required this.roads,
    required this.episodesByNumber,
    required this.displayRoadToOriginalRoad,
    required this.originalRoadToDisplayRoad,
  });

  final List<Road> roads;
  final Map<int, DownloadEpisode> episodesByNumber;
  final Map<int, int> displayRoadToOriginalRoad;
  final Map<int, int> originalRoadToDisplayRoad;
}

OfflineRoadListSnapshot buildOfflineRoadListSnapshot(
  List<DownloadEpisode> episodes,
) {
  final groupedEpisodes = <int, List<DownloadEpisode>>{};
  final episodesByNumber = <int, DownloadEpisode>{};

  for (final episode in episodes) {
    episodesByNumber[episode.episodeNumber] = episode;
    groupedEpisodes.putIfAbsent(episode.road, () => []).add(episode);
  }

  final originalRoads = groupedEpisodes.keys.toList()..sort();
  final roads = <Road>[];
  final displayRoadToOriginalRoad = <int, int>{};
  final originalRoadToDisplayRoad = <int, int>{};

  for (final originalRoad in originalRoads) {
    final roadEpisodes = groupedEpisodes[originalRoad]!
      ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
    final displayRoad = roads.length;
    displayRoadToOriginalRoad[displayRoad] = originalRoad;
    originalRoadToDisplayRoad[originalRoad] = displayRoad;
    roads.add(
      Road(
        name: originalRoad >= 0
            ? '播放列表${originalRoad + 1}'
            : '播放列表${displayRoad + 1}',
        data: roadEpisodes.map((e) => e.episodeNumber.toString()).toList(),
        identifier: roadEpisodes
            .map(
              (e) => e.episodeName.isNotEmpty
                  ? e.episodeName
                  : '第${e.episodeNumber}集',
            )
            .toList(),
      ),
    );
  }

  return OfflineRoadListSnapshot(
    roads: roads,
    episodesByNumber: episodesByNumber,
    displayRoadToOriginalRoad: displayRoadToOriginalRoad,
    originalRoadToDisplayRoad: originalRoadToDisplayRoad,
  );
}

class EpisodeRef {
  const EpisodeRef({
    required this.listIndex,
    required this.roadIndex,
    required this.displayTitle,
    required this.pageUrl,
    required this.sortNumber,
    required this.historyEpisodeNumber,
    required this.danmakuEpisodeNumber,
    required this.originalRoadIndex,
  });

  final int listIndex;
  final int roadIndex;
  final String displayTitle;
  final String pageUrl;

  /// Episode sort number.
  /// - Online: parsed from [displayTitle] via [extractEpisodeNumber];
  ///   null when unparsable.
  /// - Offline: always the download record's episodeNumber.
  final int? sortNumber;
  final int historyEpisodeNumber;
  final int danmakuEpisodeNumber;
  final int originalRoadIndex;

  factory EpisodeRef.online({
    required int listIndex,
    required int roadIndex,
    required String displayTitle,
    required String pageUrl,
    int? contentEpisodeNumber,
  }) {
    final parsedEpisodeNumber =
        contentEpisodeNumber ?? extractEpisodeNumber(displayTitle);
    return EpisodeRef(
      listIndex: listIndex,
      roadIndex: roadIndex,
      displayTitle: displayTitle,
      pageUrl: pageUrl,
      sortNumber: parsedEpisodeNumber > 0 ? parsedEpisodeNumber : null,
      historyEpisodeNumber: episodeHistorySlot(pageUrl, listIndex),
      danmakuEpisodeNumber: contentEpisodeNumber == 0
          ? 0
          : parsedEpisodeNumber > 0
          ? parsedEpisodeNumber
          : listIndex,
      originalRoadIndex: roadIndex,
    );
  }

  const factory EpisodeRef.offline({
    required int listIndex,
    required int roadIndex,
    required String displayTitle,
    required String pageUrl,
    required int episodeNumber,
    required int originalRoadIndex,
    int? contentEpisodeNumber,
  }) = _OfflineEpisodeRef;
}

class _OfflineEpisodeRef extends EpisodeRef {
  const _OfflineEpisodeRef({
    required super.listIndex,
    required super.roadIndex,
    required super.displayTitle,
    required super.pageUrl,
    required int episodeNumber,
    required super.originalRoadIndex,
    int? contentEpisodeNumber,
  }) : super(
         sortNumber: contentEpisodeNumber == 0
             ? null
             : (contentEpisodeNumber ?? episodeNumber),
         historyEpisodeNumber: episodeNumber,
         danmakuEpisodeNumber: contentEpisodeNumber ?? episodeNumber,
       );
}
