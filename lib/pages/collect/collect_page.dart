import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bangumi/airing_summary.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/broadcast_slot.dart';
import 'package:kazumi/modules/bangumi/sync_priority.dart';
import 'package:kazumi/modules/collect/collect_layout.dart';
import 'package:kazumi/modules/collect/collect_progress.dart';
import 'package:kazumi/modules/collect/collect_sync_plan.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/collect/collect_library_view.dart';
import 'package:kazumi/pages/collect/collect_sync_dialog.dart';
import 'package:kazumi/pages/collect/episode_picker_sheet.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/request/apis/airtime_api.dart';
import 'package:kazumi/request/apis/main_episode_cache.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/history_playback_service.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart'
    show RuleCancelToken;
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/pages/subject/subject_note_dialog.dart';
import 'package:kazumi/pages/subject/subject_poster.dart';
import 'package:kazumi/services/subject/subject_local_store.dart';
import 'package:kazumi/services/subject/subject_watch.dart';
import 'package:kazumi/services/sync/watched_episode_service.dart';
import 'package:kazumi/utils/device.dart';

class CollectPage extends StatefulWidget {
  const CollectPage({super.key, required this.controller});

  final CollectController controller;

  @override
  State<CollectPage> createState() => _CollectPageState();
}

class _CollectPageState extends State<CollectPage>
    with KazumiDialogOwner, WidgetsBindingObserver {
  static const _syncSettings = [
    SettingsKeys.webDavEnable,
    SettingsKeys.webDavEnableCollect,
    SettingsKeys.bangumiSyncEnable,
  ];

  /// Episode lists requested at once for the airing progress.
  static const _airingConcurrency = 3;

  CollectController get collectController => widget.controller;
  final HistoryController _historyController = inject<HistoryController>();
  final SubjectNotes _notes = inject<SubjectNotes>();
  final EpisodeMarks _marks = inject<EpisodeMarks>();
  late final WatchedEpisodeService _episodeSync = WatchedEpisodeService(
    collectController,
  );
  final HistoryPlaybackService _playbackService =
      inject<HistoryPlaybackService>();
  bool get _syncDialogOpen => dialogs.isRunning;
  final Set<int> _pendingIds = {};
  late CollectLayout _layout;
  StreamSubscription<void>? _syncSettingsSubscription;

  Map<int, BroadcastSlot> _airtimes = const {};
  final Map<int, AiringSummary> _airing = {};
  final Set<int> _airingRequested = {};
  final List<int> _airingQueue = [];
  int _airingRunning = 0;
  Timer? _broadcastTimer;

  CollectSyncPlan get _syncPlan => CollectSyncPlan(
    webDavEnabled: GStorage.getSetting(SettingsKeys.webDavEnable),
    webDavCollectiblesEnabled: GStorage.getSetting(
      SettingsKeys.webDavEnableCollect,
    ),
    bangumiEnabled: GStorage.getSetting(SettingsKeys.bangumiSyncEnable),
  );

  Future<bool> _syncStep(
    CollectSyncStep step, {
    required ValueChanged<String> onError,
    required void Function(String message, int current, int total) onProgress,
  }) => switch (step) {
    CollectSyncStep.webDav => collectController.syncCollectibles(
      onError: onError,
    ),
    CollectSyncStep.bangumi => collectController.syncCollectiblesBangumi(
      onError: onError,
      onProgress: onProgress,
    ),
    CollectSyncStep.upload => collectController.uploadCollectiblesToWebDav(
      onError: onError,
    ),
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _broadcastTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted &&
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused) {
        setState(() {});
      }
    });
    _layout = CollectLayout.fromValue(
      GStorage.getSetting(SettingsKeys.defaultCollectLayout),
    );
    collectController.loadCollectibles();
    _historyController.init();
    _syncSettingsSubscription = GStorage.watchSettings(
      _syncSettings,
    ).listen((_) => mounted ? setState(() {}) : null);
    AirtimeApi.load()
        .then((airtimes) {
          if (mounted) setState(() => _airtimes = airtimes);
        })
        .catchError((Object e) {
          KazumiLogger().w('Collect: broadcast times unavailable', error: e);
        });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _broadcastTimer?.cancel();
    _syncSettingsSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) setState(() {});
  }

  void _changeLayout(CollectLayout layout) {
    if (_layout == layout) return;
    setState(() => _layout = layout);
    GStorage.putSetting(SettingsKeys.defaultCollectLayout, layout.name);
  }

  /// Airing progress is fetched for shows being watched only.
  void _requestAiring(Iterable<BangumiItem> items) {
    for (final item in items) {
      if (_airingRequested.add(item.id)) _airingQueue.add(item.id);
    }
    while (_airingRunning < _airingConcurrency && _airingQueue.isNotEmpty) {
      _airingRunning++;
      unawaited(_loadAiring(_airingQueue.removeAt(0)));
    }
  }

  Future<void> _loadAiring(int id) async {
    try {
      final episodes = await MainEpisodeCache.get(id);
      if (mounted && episodes.isNotEmpty) {
        setState(
          () => _airing[id] = AiringSummary.of(episodes, today: DateTime.now()),
        );
      }
    } catch (e) {
      // Retried the next time the page asks for it.
      _airingRequested.remove(id);
      KazumiLogger().w('Collect: episode list unavailable', error: e);
    } finally {
      _airingRunning--;
      if (mounted) _requestAiring(const []);
    }
  }

  Map<int, CollectProgress> _progress(List<History> histories) {
    final now = DateTime.now();
    final latest = <int, History>{};
    for (final history in histories) {
      final id = history.bangumiItem.id;
      final current = latest[id];
      if (current == null ||
          history.lastWatchTime.isAfter(current.lastWatchTime)) {
        latest[id] = history;
      }
    }
    // Only shows with manual marks need their recorded episodes.
    final marked = <int, Map<int, bool>>{
      for (final entry in collectController.collectibles)
        if (_marks.marksFor(entry.bangumiItem.id) case final marks
            when marks.isNotEmpty)
          entry.bangumiItem.id: marks,
    };
    final recorded = <int, Set<int>>{};
    if (marked.isNotEmpty) {
      for (final history in histories) {
        final id = history.bangumiItem.id;
        if (!marked.containsKey(id)) continue;
        final episodes = recorded.putIfAbsent(id, () => <int>{});
        for (final progress in history.progresses.values) {
          if (progress.episodeNumber > 0) episodes.add(progress.episodeNumber);
        }
      }
    }
    final progress = <int, CollectProgress>{};
    for (final entry in collectController.collectibles) {
      final id = entry.bangumiItem.id;
      final history = latest[id];
      final slot = _airtimes[id];
      final storedAiring = _airing[id];
      final airing = storedAiring == null
          ? null
          : AiringSummary.of(
              storedAiring.episodes,
              plannedTotal: storedAiring.total,
              today: now,
              slot: slot,
              requireBroadcastTime: true,
            );
      final marks = marked[id];
      final lastWatched = marks == null
          ? null
          : SubjectWatch(
              latest: history,
              watched: SubjectWatch.watchedWith(recorded[id] ?? {}, marks),
              marks: marks,
            ).lastWatched;
      if (history != null ||
          airing != null ||
          slot != null ||
          lastWatched != null) {
        progress[id] = CollectProgress(
          history: history,
          airing: airing,
          slot: slot,
          lastWatched: lastWatched,
        );
      }
    }
    return progress;
  }

  Future<void> _changeType(
    BangumiItem item,
    CollectType type, {
    bool offerUndo = true,
  }) async {
    if (_syncDialogOpen || _pendingIds.contains(item.id)) return;
    final previous = CollectType.fromValue(
      collectController.getCollectType(item),
    );
    setState(() => _pendingIds.add(item.id));
    try {
      await collectController.addCollect(item, type: type.value);
    } catch (_) {
      KazumiDialog.showToast(message: '修改收藏状态失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _pendingIds.remove(item.id));
    }
    final current = CollectType.fromValue(
      collectController.getCollectType(item),
    );
    // Bangumi may have refused, or a dialog may have been cancelled.
    if (!offerUndo || current == previous || !mounted) return;
    final title = item.nameCn.isNotEmpty ? item.nameCn : item.name;
    KazumiDialog.showToast(
      message: current.isCollected
          ? '《$title》已改为「${current.label}」'
          : '已取消收藏《$title》',
      showActionButton: true,
      actionLabel: '撤销',
      duration: const Duration(seconds: 6),
      onActionPressed: () => _changeType(item, previous, offerUndo: false),
    );
  }

  /// The latest watch record of [item] across playback libraries.
  History? _latestHistory(BangumiItem item) {
    History? latest;
    for (final record in _historyController.histories) {
      if (record.bangumiItem.id == item.id &&
          (latest == null ||
              record.lastWatchTime.isAfter(latest.lastWatchTime))) {
        latest = record;
      }
    }
    return latest;
  }

  /// Resumes the watch record, or starts a show never played.
  void _play(BangumiItem item) {
    if (_syncDialogOpen) return;
    if (_latestHistory(item) != null) {
      unawaited(_resume(item));
    } else {
      context.pushNamed(
        '/video/',
        arguments: OnlineVideoPlaybackArgs(bangumiItem: item),
      );
    }
  }

  void _playEpisode(BangumiItem item, int number) {
    if (_syncDialogOpen) return;
    context.pushNamed(
      '/video/',
      arguments: OnlineVideoPlaybackArgs(
        bangumiItem: item,
        startEpisodeNumber: number,
      ),
    );
  }

  void _pickEpisode(BangumiItem item) {
    if (_syncDialogOpen) return;
    final watch = SubjectWatch.of(
      _historyController.histories,
      item.id,
      marks: _marks.marksFor(item.id),
    );
    showAdaptiveBottomSheet<void>(
      context: context,
      maxHeightFactor: 0.8,
      builder: (_) => EpisodePickerSheet(
        bangumiItem: item,
        watched: watch.watched,
        lastWatched: watch.lastWatched,
        onPlay: (number) => _playEpisode(item, number),
        onDetails: () => context.pushNamed('/info/', arguments: item),
        onMark: (episodes, watched) => _markEpisodes(item, episodes, watched),
      ),
    );
  }

  Future<void> _markEpisodes(
    BangumiItem item,
    List<int> episodes,
    bool watched,
  ) async {
    await _marks.mark(item.id, episodes, watched: watched);
    unawaited(_episodeSync.syncManualMarks(item, episodes, watched: watched));
  }

  void _editNote(BangumiItem item) {
    if (_syncDialogOpen) return;
    unawaited(showSubjectNoteEditor(context, item: item, notes: _notes));
  }

  void _share(BangumiItem item) {
    if (_syncDialogOpen) return;
    unawaited(showSubjectPoster(context, item: item));
  }

  Future<void> _resume(BangumiItem item) async {
    if (_syncDialogOpen) return;
    final history = _latestHistory(item);
    if (history == null) return;
    final record = history;
    await dialogs.run((task) async {
      final cancelToken = RuleCancelToken();
      final result = await task.loading(
        message: '获取中',
        barrierDismissible: isDesktop(),
        onCancel: cancelToken.cancel,
        action: () => _playbackService.open(record, cancelToken: cancelToken),
      );
      switch (result) {
        case HistoryPlaybackReady(:final args):
          task.withContext(
            (context) => context.pushNamed('/video/', arguments: args),
          );
        case HistoryPlaybackUnavailable(:final reason):
          KazumiDialog.showToast(message: reason);
      }
    }, errorMessage: '暂时无法继续播放，请稍后重试');
  }

  Future<void> _sync() async {
    if (_syncDialogOpen || _pendingIds.isNotEmpty) return;
    final plan = _syncPlan;
    await dialogs.run((task) async {
      final destination = await task.show<CollectSyncDestination>(
        builder: (_) => CollectSyncDialog(
          plan: plan,
          priority: BangumiSyncPriority.fromValue(
            GStorage.getSetting(SettingsKeys.bangumiSyncPriority),
          ),
          onSync: _syncStep,
        ),
      );
      task.withContext(
        (context) => context.pushNamed(switch (destination) {
          CollectSyncDestination.webDavSettings => '/settings/webdav/',
          CollectSyncDestination.bangumiSettings => '/settings/bangumi/',
        }),
      );
    }, errorMessage: '同步未完成，请稍后重试');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SysAppBar(
        needTopOffset: false,
        title: const Text('追番'),
        // Line the title up with the library column below.
        contentWidth: (width) {
          final inset =
              (width - width.clamp(0.0, 1560.0)) / 2 + (width < 600 ? 16 : 32);
          return width - inset * 2 + 40;
        },
        actions: [
          // Only offered once WebDAV or Bangumi sync is set up.
          if (_syncPlan.canSync)
            IconButton(
              tooltip: '同步收藏',
              onPressed: _syncDialogOpen || _pendingIds.isNotEmpty
                  ? null
                  : _sync,
              icon: const Icon(Icons.sync_rounded),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        // Notes and marks change rarely; one listener rebuilds the list.
        child: ListenableBuilder(
          listenable: Listenable.merge([_notes, _marks]),
          builder: (context, _) => Observer(
            builder: (context) {
              final entries = collectController.collectibles.toList();
              final progress = _progress(_historyController.histories.toList());
              final watching = [
                for (final entry in entries)
                  if (entry.type == CollectType.watching.value)
                    entry.bangumiItem,
              ];
              if (watching.any((item) => !_airingRequested.contains(item.id))) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _requestAiring(watching);
                });
              }
              return CollectLibraryView(
                entries: entries,
                showRating: GStorage.getSetting(SettingsKeys.showRating),
                layout: _layout,
                onLayoutChanged: _changeLayout,
                progress: progress,
                canEdit: (item) =>
                    !_syncDialogOpen && !_pendingIds.contains(item.id),
                onOpen: (item) => context.pushNamed('/info/', arguments: item),
                onChangeType: (item, type) =>
                    unawaited(_changeType(item, type)),
                onPlay: _play,
                onPickEpisode: _pickEpisode,
                notes: {
                  for (final entry in entries)
                    entry.bangumiItem.id: ?_notes.noteFor(
                      entry.bangumiItem.id,
                    ),
                },
                onEditNote: _editNote,
                onShare: _share,
              );
            },
          ),
        ),
      ),
    );
  }
}
