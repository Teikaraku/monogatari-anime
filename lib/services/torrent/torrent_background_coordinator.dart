import 'dart:async';

import 'package:kazumi/services/download/background_download_service.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/torrent/torrent_models.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:kazumi/utils/format.dart';

/// Shares Android's existing foreground service without owning BT downloads
/// or replacing the HTTP navigation/permission handlers registered at startup.
class TorrentBackgroundCoordinator {
  TorrentBackgroundCoordinator(
    this.torrents, {
    BackgroundDownloadService? backgroundService,
    this.onNavigateRequested,
  }) : background = backgroundService ?? BackgroundDownloadService();

  final TorrentService torrents;
  final BackgroundDownloadService background;
  final void Function()? onNavigateRequested;
  StreamSubscription<List<TorrentTaskSnapshot>>? _subscription;
  bool _started = false;
  bool _disposed = false;
  bool _pausingBlockedWork = false;
  final Map<String, Future<void>> _taskPauses = {};

  void start() {
    if (_started || _disposed || !background.isSupported) return;
    _started = true;
    background.registerOwner(
      BackgroundDownloadOwner.rss,
      onPause: pauseAll,
      onNavigate: onNavigateRequested,
    );
    _subscription = torrents.watchTasks.listen(
      _update,
      onError: (Object error) => KazumiLogger().w(
        'TorrentBackgroundCoordinator: task stream failed',
        error: error,
      ),
    );
    _update(torrents.tasks);
  }

  void _update(List<TorrentTaskSnapshot> _) {
    if (_disposed) return;
    // Task notifications are asynchronous. Several pauses may finish before
    // their earlier snapshots arrive; reading the latest state prevents an
    // old downloading snapshot from reacquiring an already released owner.
    final tasks = torrents.tasks;
    final active = tasks
        .where(
          (task) => const {
            TorrentTaskState.metadata,
            TorrentTaskState.downloading,
            TorrentTaskState.buffering,
          }.contains(task.state),
        )
        .toList();
    final pending = torrents.pendingMetadataCount;
    final count = active.length + pending;
    if (background.requiresUserResume && count > 0) {
      if (!_pausingBlockedWork) {
        _pausingBlockedWork = true;
        final pausedIds = active.map((task) => task.id).toSet();
        unawaited(
          pauseAll().whenComplete(() {
            _pausingBlockedWork = false;
            // Work can be created while earlier tasks are still pausing. Only
            // retry for new work, never recursively retry a failed old pause.
            if (!_disposed &&
                (torrents.tasks.any(
                      (task) =>
                          !pausedIds.contains(task.id) &&
                          const {
                            TorrentTaskState.metadata,
                            TorrentTaskState.downloading,
                            TorrentTaskState.buffering,
                          }.contains(task.state),
                    ) ||
                    (pending == 0 && torrents.pendingMetadataCount > 0))) {
              _update(torrents.tasks);
            }
          }),
        );
      }
      return;
    }
    final work = count == 0
        ? background.stopService(owner: BackgroundDownloadOwner.rss)
        : background.updateProgress(
            owner: BackgroundDownloadOwner.rss,
            activeCount: active.length,
            totalCount: count,
            overallProgress:
                active.fold<double>(
                  0.0,
                  (sum, task) =>
                      sum +
                      (task.progress.isFinite ? task.progress.clamp(0, 1) : 0),
                ) /
                count,
            speedText: formatSpeed(
              active.fold<double>(
                0.0,
                (sum, task) => sum + task.downloadBytesPerSecond,
              ),
            ),
            bytesPerSecond: active.fold<double>(
              0.0,
              (sum, task) => sum + task.downloadBytesPerSecond,
            ),
          );
    unawaited(
      work.catchError((Object error) {
        KazumiLogger().w(
          'TorrentBackgroundCoordinator: foreground update failed',
          error: error,
        );
      }),
    );
  }

  Future<void> pauseAll() async {
    torrents.cancelPendingMetadata();
    final active = torrents.tasks
        .where(
          (task) => const {
            TorrentTaskState.metadata,
            TorrentTaskState.downloading,
            TorrentTaskState.buffering,
          }.contains(task.state),
        )
        .toList();
    await Future.wait(active.map((task) => _pauseTask(task.id)));
    if (!_disposed) _update(torrents.tasks);
  }

  Future<void> _pauseTask(String id) {
    final pending = _taskPauses[id];
    if (pending != null) return pending;
    late final Future<void> work;
    work = Future<void>.sync(() => torrents.pause(id))
        .catchError((Object error) {
          KazumiLogger().w(
            'TorrentBackgroundCoordinator: pause failed',
            error: error,
          );
        })
        .whenComplete(() {
          if (identical(_taskPauses[id], work)) _taskPauses.remove(id);
        });
    _taskPauses[id] = work;
    return work;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    await background.unregisterOwner(BackgroundDownloadOwner.rss);
  }
}
