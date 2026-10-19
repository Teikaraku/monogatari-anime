import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/download/background_download_service.dart';
import 'package:kazumi/services/torrent/torrent_background_coordinator.dart';
import 'package:kazumi/services/torrent/torrent_models.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:logger/logger.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    Logger.level = Level.off;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  tearDown(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );
  test(
    'HTTP and RSS share one service and aggregate both task counts and speed',
    () async {
      final driver = _Driver();
      final service = driver.service;
      await Future.wait([
        service.startService(owner: BackgroundDownloadOwner.http),
        service.startService(owner: BackgroundDownloadOwner.rss),
      ]);
      await service.updateProgress(
        activeCount: 2,
        totalCount: 2,
        overallProgress: 0.5,
        speedText: '',
        bytesPerSecond: 200,
      );
      await service.updateProgress(
        owner: BackgroundDownloadOwner.rss,
        activeCount: 2,
        totalCount: 3,
        overallProgress: 0.25,
        speedText: '',
        bytesPerSecond: 300,
      );
      expect(driver.starts, 1);
      expect(driver.updates.last.$1, '正在下载 (4/5)');
      expect(driver.updates.last.$2, contains('在线播放 2 · RSS 3 · 35%'));
      expect(driver.updates.last.$2, contains('500 B/s'));
      await service.stopService(owner: BackgroundDownloadOwner.http);
      expect(service.isRunning, isTrue);
      expect(driver.stops, 0);
      expect(driver.updates.last.$2, contains('RSS 3'));
      expect(driver.updates.last.$2, isNot(contains('在线播放')));
      await service.stopService(owner: BackgroundDownloadOwner.rss);
      expect(service.isRunning, isFalse);
      expect(driver.stops, 1);
    },
  );

  test(
    'releasing HTTP during pending platform start preserves a new RSS owner',
    () async {
      final started = Completer<void>();
      final completion = Completer<bool>();
      var starts = 0;
      var stops = 0;
      final service = BackgroundDownloadService.forTesting(
        supported: true,
        start: () {
          starts++;
          started.complete();
          return completion.future;
        },
        stop: () async {
          stops++;
        },
        update: (_, _) async {},
      );
      final http = service.startService();
      await started.future;
      final rss = service.startService(owner: BackgroundDownloadOwner.rss);
      final release = service.stopService();
      completion.complete(true);
      expect(await http, isFalse);
      expect(await rss, isTrue);
      await release;
      expect(service.isRunning, isTrue);
      expect(starts, 1);
      expect(stops, 0);
      await service.stopService(owner: BackgroundDownloadOwner.rss);
      expect(stops, 1);
    },
  );

  test(
    'pause all fans out once to both owners even when one callback fails',
    () async {
      final driver = _Driver();
      final service = driver.service;
      final pending = Completer<void>();
      var http = 0;
      var rss = 0;
      service.registerOwner(
        BackgroundDownloadOwner.http,
        onPause: () async {
          http++;
          await pending.future;
          throw StateError('HTTP cleanup failed');
        },
      );
      service.registerOwner(
        BackgroundDownloadOwner.rss,
        onPause: () async {
          rss++;
        },
      );
      final first = service.pauseAllOwners();
      final second = service.pauseAllOwners();
      expect(identical(first, second), isTrue);
      expect(http, 1);
      expect(rss, 1);
      pending.complete();
      await Future.wait([first, second]);
    },
  );

  test(
    'RSS-only navigation is additive and leaves the startup HTTP callback intact',
    () async {
      final driver = _Driver();
      final service = driver.service;
      var http = 0;
      var rss = 0;
      void legacyNavigation() {
        http++;
      }

      service.onNavigateToDownloadRequested = legacyNavigation;
      service.registerOwner(
        BackgroundDownloadOwner.rss,
        onPause: () {},
        onNavigate: () {
          rss++;
        },
      );
      await service.startService();
      await service.startService(owner: BackgroundDownloadOwner.rss);
      service.handleNavigateToDownload();
      expect(http, 1);
      await service.stopService();
      service.handleNavigateToDownload();
      expect(rss, 1);
      expect(service.onNavigateToDownloadRequested, same(legacyNavigation));
      await service.stopService(owner: BackgroundDownloadOwner.rss);
    },
  );

  test(
    'coordinator keeps metadata alive and pause all handles pending and active RSS plus HTTP',
    () async {
      final driver = _Driver();
      final service = driver.service;
      final torrent = _Torrents()
        ..metadataCount = 1
        ..snapshots = [
          _task('download', TorrentTaskState.downloading),
          _task('stream', TorrentTaskState.buffering),
          _task('done', TorrentTaskState.completed),
        ];
      final coordinator = TorrentBackgroundCoordinator(
        torrent,
        backgroundService: service,
      );
      addTearDown(torrent.close);
      addTearDown(coordinator.dispose);
      var httpPaused = 0;
      service.registerOwner(
        BackgroundDownloadOwner.http,
        onPause: () async {
          httpPaused++;
          await service.stopService();
        },
      );
      await service.updateProgress(
        activeCount: 1,
        totalCount: 1,
        overallProgress: 0.5,
        speedText: '',
        bytesPerSecond: 0,
      );
      coordinator.start();
      await _flush();
      expect(driver.starts, 1);
      expect(driver.updates.last.$2, contains('在线播放 1 · RSS 3'));
      await service.pauseAllOwners();
      await _flush();
      expect(httpPaused, 1);
      expect(torrent.pendingCancelled, 1);
      expect(torrent.paused, ['download', 'stream']);
      expect(service.isRunning, isFalse);
      expect(driver.stops, 1);
    },
  );

  test(
    'disposing the RSS observer neither stops HTTP nor pauses business tasks',
    () async {
      final driver = _Driver();
      final service = driver.service;
      final torrent = _Torrents()
        ..snapshots = [_task('rss', TorrentTaskState.downloading)];
      final coordinator = TorrentBackgroundCoordinator(
        torrent,
        backgroundService: service,
      );
      addTearDown(torrent.close);
      await service.startService();
      coordinator.start();
      await _flush();
      await coordinator.dispose();
      expect(service.isRunning, isTrue);
      expect(driver.stops, 0);
      expect(torrent.events.hasListener, isFalse);
      expect(torrent.paused, isEmpty);
      await service.stopService();
      expect(driver.stops, 1);
    },
  );

  test('timeout event stops both owners and rejects repeated events', () async {
    final driver = _Driver();
    final service = driver.service;
    final paused = <BackgroundDownloadOwner>[];
    for (final owner in BackgroundDownloadOwner.values) {
      service.registerOwner(owner, onPause: () => paused.add(owner));
      await service.startService(owner: owner);
    }
    final session = service.runningSession!;
    final stopped = service.handleTaskData(_destroyed(session));
    expect(service.isRunning, isFalse);
    expect(service.requiresUserResume, isTrue);
    await stopped;
    expect(paused, BackgroundDownloadOwner.values);
    await service.handleTaskData(_destroyed(session));
    await service.handleTaskData(_destroyed('unrelated-session'));
    expect(paused, BackgroundDownloadOwner.values);
    expect(driver.starts, 1);
    // Android has already stopped the service; do not stop its replacement.
    expect(driver.stops, 0);
  });

  test('timeout cannot resurrect a late native start response', () async {
    final started = Completer<void>();
    final completion = Completer<bool>();
    final service = BackgroundDownloadService.forTesting(
      supported: true,
      start: () {
        started.complete();
        return completion.future;
      },
      stop: () async {},
      update: (_, _) async {},
    );
    var paused = 0;
    service.registerOwner(
      BackgroundDownloadOwner.http,
      onPause: () {
        paused++;
      },
    );
    final pending = service.startService();
    await started.future;
    await service.handleTaskData(_destroyed(service.runningSession!));
    completion.complete(true);
    expect(await pending, isFalse);
    expect(service.isRunning, isFalse);
    expect(service.requiresUserResume, isTrue);
    expect(paused, 1);
  });

  test(
    'manual stop and old session events never pause a replacement',
    () async {
      final driver = _Driver();
      final service = driver.service;
      var paused = 0;
      service.registerOwner(
        BackgroundDownloadOwner.rss,
        onPause: () {
          paused++;
        },
      );
      await service.startService();
      final previous = service.runningSession!;
      await service.stopService();
      await service.startService(owner: BackgroundDownloadOwner.rss);
      final current = service.runningSession;
      await service.handleTaskData(_destroyed(previous));
      expect(service.runningSession, current);
      expect(service.isRunning, isTrue);
      expect(service.requiresUserResume, isFalse);
      expect(paused, 0);
      expect(driver.starts, 2);
      await service.stopService(owner: BackgroundDownloadOwner.rss);
    },
  );

  test(
    'user resume waits for timeout pauses and rejects background resume',
    () async {
      final driver = _Driver();
      final service = driver.service;
      final pauseStarted = Completer<void>();
      final pauseFinished = Completer<void>();
      service.registerOwner(
        BackgroundDownloadOwner.http,
        onPause: () async {
          pauseStarted.complete();
          await pauseFinished.future;
          await service.stopService();
        },
      );
      await service.startService();
      final stopped = service.handleTaskData(
        _destroyed(service.runningSession!),
      );
      await pauseStarted.future;
      var resumed = false;
      final resume = service.resumeForUser().then((_) => resumed = true);
      await _flush();
      expect(resumed, isFalse);
      expect(service.requiresUserResume, isTrue);
      // Moving to background while waiting must not unlock the service.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      pauseFinished.complete();
      await Future.wait([stopped, resume]);
      expect(service.requiresUserResume, isTrue);
      await service.resumeForUser();
      expect(service.requiresUserResume, isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await service.resumeForUser();
      expect(service.requiresUserResume, isFalse);
      expect(await service.startService(), isTrue);
      await service.stopService();
    },
  );

  test('automatic progress and start stay blocked after timeout', () async {
    final driver = _Driver();
    final service = driver.service;
    await service.startService();
    await service.handleTaskData(_destroyed(service.runningSession!));
    await service.updateProgress(
      owner: BackgroundDownloadOwner.rss,
      activeCount: 1,
      totalCount: 1,
      overallProgress: 0,
      speedText: '',
    );
    expect(await service.startService(), isFalse);
    expect(driver.starts, 1);
    expect(service.isRunning, isFalse);
    expect(service.requiresUserResume, isTrue);
  });

  test(
    'unexpected service destruction pauses work while cleanup is pending',
    () async {
      final driver = _Driver();
      final service = driver.service;
      final paused = Completer<void>();
      service.registerOwner(
        BackgroundDownloadOwner.http,
        onPause: () => paused.future,
      );
      await service.startService();
      final stopped = service.handleTaskData(
        _destroyed(service.runningSession!, timeout: false),
      );
      final automatic = service.startService(
        owner: BackgroundDownloadOwner.rss,
      );
      await _flush();
      expect(service.isRunning, isFalse);
      expect(driver.starts, 1);
      paused.complete();
      await stopped;
      expect(await automatic, isFalse);
      expect(service.requiresUserResume, isFalse);
    },
  );

  test(
    'blocked coordinator pauses new BT work instead of leaving it unprotected',
    () async {
      final driver = _Driver();
      final service = driver.service;
      final torrent = _Torrents()
        ..snapshots = [_task('original', TorrentTaskState.downloading)];
      final coordinator = TorrentBackgroundCoordinator(
        torrent,
        backgroundService: service,
      );
      addTearDown(torrent.close);
      addTearDown(coordinator.dispose);
      coordinator.start();
      await _flush();
      await service.handleTaskData(_destroyed(service.runningSession!));
      torrent.metadataCount = 1;
      torrent.snapshots = [
        ...torrent.snapshots,
        _task('automatic-next', TorrentTaskState.buffering),
      ];
      torrent.events.add(torrent.snapshots);
      await _flush();
      await _flush();
      expect(torrent.pendingCancelled, 1);
      expect(torrent.paused, ['original', 'automatic-next']);
      expect(torrent.snapshots.last.state, TorrentTaskState.paused);
      expect(driver.starts, 1);
      expect(service.isRunning, isFalse);
      await service.resumeForUser();
      torrent.snapshots = [
        ...torrent.snapshots,
        _task('user-next', TorrentTaskState.downloading),
      ];
      torrent.events.add(torrent.snapshots);
      await _flush();
      expect(driver.starts, 2);
      expect(service.isRunning, isTrue);
    },
  );
}

Map<String, Object> _destroyed(String session, {bool timeout = true}) => {
  'action': 'service_destroyed',
  'session': session,
  'isTimeout': timeout,
};

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _Driver {
  int starts = 0;
  int stops = 0;
  final updates = <(String, String)>[];
  late final service = BackgroundDownloadService.forTesting(
    supported: true,
    start: () async {
      starts++;
      return true;
    },
    stop: () async {
      stops++;
    },
    update: (title, text) async {
      updates.add((title, text));
    },
  );
}

class _Torrents implements TorrentService {
  final events = StreamController<List<TorrentTaskSnapshot>>.broadcast();
  List<TorrentTaskSnapshot> snapshots = [];
  int metadataCount = 0;
  int pendingCancelled = 0;
  final paused = <String>[];
  @override
  List<TorrentTaskSnapshot> get tasks => snapshots;
  @override
  Stream<List<TorrentTaskSnapshot>> get watchTasks => events.stream;
  @override
  int get pendingMetadataCount => metadataCount;
  @override
  void cancelPendingMetadata() {
    pendingCancelled += metadataCount;
    metadataCount = 0;
    events.add(snapshots);
  }

  @override
  Future<void> pause(String id) async {
    paused.add(id);
    snapshots = snapshots
        .map(
          (task) => task.id == id
              ? task.copyWith(state: TorrentTaskState.paused)
              : task,
        )
        .toList();
    events.add(snapshots);
  }

  Future<void> close() => events.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TorrentTaskSnapshot _task(String id, TorrentTaskState state) =>
    TorrentTaskSnapshot(
      id: id,
      source: Uri.parse(
        'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
      ),
      title: id,
      state: state,
      progress: 0.5,
      totalBytes: 1000,
      downloadedBytes: 500,
    );
