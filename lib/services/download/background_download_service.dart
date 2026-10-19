import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/format.dart';

enum BackgroundDownloadOwner { http, rss }

const _foregroundSessionKey = 'download_foreground_session';

/// Android 后台下载服务
///
/// 使用 Foreground Service 保持 app 进程存活，防止系统在后台时杀死下载进程。
/// 下载逻辑仍在主 Isolate 运行，此服务仅负责：
/// 1. 显示通知栏进度
/// 2. 保持进程存活
/// 3. 提供通知栏交互（暂停全部）
class BackgroundDownloadService {
  static final BackgroundDownloadService _instance =
      BackgroundDownloadService._internal();
  factory BackgroundDownloadService() => _instance;
  BackgroundDownloadService._internal()
    : _supportedOverride = null,
      _startOverride = null,
      _stopOverride = null,
      _updateOverride = null;

  @visibleForTesting
  BackgroundDownloadService.forTesting({
    required bool supported,
    required Future<bool> Function() start,
    required Future<void> Function() stop,
    required Future<void> Function(String title, String text) update,
  }) : _supportedOverride = supported,
       _startOverride = start,
       _stopOverride = stop,
       _updateOverride = update;

  final bool? _supportedOverride;
  final Future<bool> Function()? _startOverride;
  final Future<void> Function()? _stopOverride;
  final Future<void> Function(String, String)? _updateOverride;
  final Set<BackgroundDownloadOwner> _owners = {};
  final Map<BackgroundDownloadOwner, _OwnerProgress> _progress = {};
  final Map<BackgroundDownloadOwner, FutureOr<void> Function()> _pauseHandlers =
      {};
  final Map<BackgroundDownloadOwner, void Function()> _navigationHandlers = {};
  Future<void> _nativeOperations = Future.value();
  Future<void>? _pausingAll;
  Future<void>? _systemPause;
  String? _activeSession;
  int _sessionNumber = 0;
  bool _requiresUserResume = false;

  bool _isInitialized = false;
  bool _isRunning = false;

  void Function()? onPauseAll;
  void Function()? onNavigateToDownloadRequested;

  /// 返回 true 表示用户同意请求权限，false 表示用户拒绝
  Future<bool> Function()? onNotificationPermissionRequired;

  bool get isSupported => _supportedOverride ?? Platform.isAndroid;
  bool get isRunning => _isRunning;
  bool get requiresUserResume => _requiresUserResume;

  @visibleForTesting
  String? get runningSession => _activeSession;

  /// Only a foreground user action may resume after Android's data-sync limit.
  /// Waiting prevents a late timeout pause from cancelling the resumed work.
  Future<void> resumeForUser() async {
    if (!isSupported || !_isForeground) return;
    while (_systemPause != null) {
      final pause = _systemPause!;
      await pause;
    }
    if (_isForeground) _requiresUserResume = false;
  }

  bool get _isForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  Future<void> init() async {
    if (!isSupported || _isInitialized) return;
    if (_startOverride != null) {
      _isInitialized = true;
      return;
    }

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'kazumi_download_channel',
        channelName: '下载服务',
        channelDescription: '视频下载后台服务',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowAutoRestart: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    FlutterForegroundTask.initCommunicationPort();
    // A single dispatcher fans out to all owners. Registering one plugin
    // callback per download type would process every notification twice.
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);

    _isInitialized = true;
    KazumiLogger().i('BackgroundDownloadService: initialized');
  }

  Future<bool> needsNotificationPermission() async {
    if (!isSupported) return false;
    final permission =
        await FlutterForegroundTask.checkNotificationPermission();
    return permission != NotificationPermission.granted;
  }

  Future<bool> requestNotificationPermission() async {
    if (!isSupported) return true;
    final result = await FlutterForegroundTask.requestNotificationPermission();
    return result == NotificationPermission.granted;
  }

  void registerOwner(
    BackgroundDownloadOwner owner, {
    required FutureOr<void> Function() onPause,
    void Function()? onNavigate,
  }) {
    _pauseHandlers[owner] = onPause;
    if (onNavigate != null) _navigationHandlers[owner] = onNavigate;
  }

  Future<void> unregisterOwner(BackgroundDownloadOwner owner) {
    _pauseHandlers.remove(owner);
    _navigationHandlers.remove(owner);
    return stopService(owner: owner);
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _nativeOperations.then((_) => action());
    _nativeOperations = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<bool> startService({
    BackgroundDownloadOwner owner = BackgroundDownloadOwner.http,
  }) {
    if (!isSupported) return Future.value(false);
    if (_requiresUserResume || _systemPause != null) {
      return pauseAllOwners().then((_) => false);
    }
    _owners.add(owner);
    return _serialize(() async {
      final running = await _reconcile();
      return running && _owners.contains(owner);
    });
  }

  Future<bool> _reconcile() async {
    if (_requiresUserResume || _systemPause != null) return false;
    if (_owners.isEmpty) {
      await _stopPlatformService();
      return false;
    }
    final running = await _startPlatformService();
    // Owners can release while an Android permission/start request is pending.
    if (_owners.isEmpty) {
      await _stopPlatformService();
      return false;
    }
    if (running) await _updateAggregateNotification();
    return running;
  }

  Future<bool> _startPlatformService() async {
    if (!isSupported) return false;
    if (_isRunning) return true;
    if (_startOverride != null) {
      final session = _newSession();
      final started = await _startOverride();
      _isRunning = started && _activeSession == session;
      if (!started && _activeSession == session) _activeSession = null;
      return _isRunning;
    }

    if (!_isInitialized) {
      await init();
    }

    final needsPermission = await needsNotificationPermission();
    if (needsPermission) {
      if (onNotificationPermissionRequired != null) {
        final userAgreed = await onNotificationPermissionRequired!();
        if (userAgreed) {
          final granted = await requestNotificationPermission();
          if (!granted) {
            KazumiLogger().w(
              'BackgroundDownloadService: notification permission denied by user',
            );
          }
        } else {
          KazumiLogger().i(
            'BackgroundDownloadService: user declined permission dialog',
          );
        }
      } else {
        // 没有设置回调，直接请求权限（兼容旧行为）
        final granted = await requestNotificationPermission();
        if (!granted) {
          KazumiLogger().w(
            'BackgroundDownloadService: notification permission denied',
          );
        }
      }
    }

    try {
      if (_owners.isEmpty || _requiresUserResume || _systemPause != null) {
        return false;
      }
      final session = _newSession();
      await FlutterForegroundTask.saveData(
        key: _foregroundSessionKey,
        value: session,
      );
      final result = await FlutterForegroundTask.startService(
        notificationIcon: const NotificationIcon(
          metaDataName: 'monogatari_notification_icon',
        ),
        notificationTitle: '正在下载',
        notificationText: '准备中...',
        notificationButtons: [
          const NotificationButton(id: 'pause_all', text: '暂停全部'),
        ],
        callback: _backgroundCallback,
      );

      _isRunning = result is ServiceRequestSuccess && _activeSession == session;
      if (!_isRunning && _activeSession == session) _activeSession = null;

      if (_isRunning) {
        KazumiLogger().i('BackgroundDownloadService: service started');
      } else {
        KazumiLogger().w(
          'BackgroundDownloadService: service start returned non-success: $result',
        );
      }
      return _isRunning;
    } catch (e) {
      _activeSession = null;
      KazumiLogger().e(
        'BackgroundDownloadService: failed to start service',
        error: e,
      );
      return false;
    }
  }

  String _newSession() => _activeSession =
      '${DateTime.now().microsecondsSinceEpoch}-${++_sessionNumber}';

  Future<void> stopService({
    BackgroundDownloadOwner owner = BackgroundDownloadOwner.http,
  }) {
    _owners.remove(owner);
    _progress.remove(owner);
    if (!isSupported) return Future.value();
    return _serialize(() async {
      await _reconcile();
    });
  }

  Future<void> _stopPlatformService() async {
    if (!isSupported || !_isRunning) return;

    // onDestroy may arrive after a replacement has started. Invalidate this
    // session before asking Android to stop so a manual stop is never a timeout.
    _activeSession = null;
    _isRunning = false;

    try {
      if (_stopOverride != null) {
        await _stopOverride();
      } else {
        await FlutterForegroundTask.stopService();
      }
      _isRunning = false;
      KazumiLogger().i('BackgroundDownloadService: service stopped');
    } catch (e) {
      KazumiLogger().e(
        'BackgroundDownloadService: failed to stop service',
        error: e,
      );
    }
  }

  Future<void> updateNotification({
    required String title,
    required String text,
  }) async {
    if (!isSupported || !_isRunning) return;

    try {
      if (_updateOverride != null) {
        await _updateOverride(title, text);
      } else {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
        );
      }
    } catch (e) {
      // 忽略更新失败，不影响下载
    }
  }

  Future<void> updateProgress({
    BackgroundDownloadOwner owner = BackgroundDownloadOwner.http,
    required int activeCount,
    required int totalCount,
    required double overallProgress,
    required String speedText,
    double? bytesPerSecond,
  }) async {
    if (!isSupported) return;
    if (totalCount <= 0) {
      await stopService(owner: owner);
      return;
    }
    if (_requiresUserResume || _systemPause != null) {
      await pauseAllOwners();
      return;
    }
    _owners.add(owner);
    _progress[owner] = _OwnerProgress(
      activeCount: activeCount,
      totalCount: totalCount,
      overallProgress: overallProgress.isFinite
          ? overallProgress.clamp(0, 1).toDouble()
          : 0,
      speedText: speedText,
      bytesPerSecond: bytesPerSecond,
    );
    await _serialize(() async {
      await _reconcile();
    });
  }

  Future<void> _updateAggregateNotification() async {
    final values = _progress.entries
        .where((item) => _owners.contains(item.key))
        .toList();
    if (values.isEmpty) {
      await updateNotification(title: '准备下载', text: '正在获取播放资源');
      return;
    }
    final active = values.fold(
      0,
      (count, item) => count + item.value.activeCount,
    );
    final total = values.fold(
      0,
      (count, item) => count + item.value.totalCount,
    );
    final percent =
        (values.fold(
                  0.0,
                  (sum, item) =>
                      sum + item.value.overallProgress * item.value.totalCount,
                ) /
                total *
                100)
            .toInt();
    final speed = values.every((item) => item.value.bytesPerSecond != null)
        ? formatSpeed(
            values.fold(0.0, (sum, item) => sum + item.value.bytesPerSecond!),
          )
        : values
              .map((item) => item.value.speedText)
              .where((text) => text.isNotEmpty)
              .join(' + ');
    final kinds = [
      if (_progress[BackgroundDownloadOwner.http] case final http?
          when _owners.contains(BackgroundDownloadOwner.http))
        '在线播放 ${http.totalCount}',
      if (_progress[BackgroundDownloadOwner.rss] case final rss?
          when _owners.contains(BackgroundDownloadOwner.rss))
        'RSS ${rss.totalCount}',
    ].join(' · ');
    await updateNotification(
      title: active > 0 ? '正在下载 ($active/$total)' : '正在准备下载 ($total 个任务)',
      text: '$kinds · $percent%${speed.isNotEmpty ? ' · $speed' : ''}',
    );
  }

  Future<void> pauseAllOwners() =>
      _pausingAll ??= _pauseAllOwners().whenComplete(() => _pausingAll = null);
  Future<void> _pauseAllOwners() async {
    final callbacks = _pauseHandlers.values.toList();
    if (!_pauseHandlers.containsKey(BackgroundDownloadOwner.http) &&
        onPauseAll != null) {
      callbacks.add(onPauseAll!);
    }
    await Future.wait(
      callbacks.map((callback) async {
        try {
          await callback();
        } catch (error) {
          KazumiLogger().w(
            'BackgroundDownloadService: pause owner failed',
            error: error,
          );
        }
      }),
    );
  }

  void _onTaskData(Object data) {
    unawaited(
      handleTaskData(data).catchError((Object error) {
        KazumiLogger().w(
          'BackgroundDownloadService: foreground event failed',
          error: error,
        );
      }),
    );
  }

  @visibleForTesting
  Future<void> handleTaskData(Object data) async {
    if (data is! Map) return;
    if (data['action'] == 'button_pressed' && data['id'] is String) {
      handleNotificationAction(data['id'] as String);
    } else if (data['action'] == 'navigate_to_download') {
      handleNavigateToDownload();
    } else if (data['action'] == 'service_destroyed') {
      final session = data['session'];
      if (session is! String || session != _activeSession) return;
      _activeSession = null;
      _isRunning = false;
      _owners.clear();
      _progress.clear();
      _requiresUserResume = data['isTimeout'] == true;
      final pause = _systemPause = Future<void>.microtask(pauseAllOwners);
      try {
        await pause;
      } finally {
        if (identical(_systemPause, pause)) _systemPause = null;
      }
    }
  }

  void handleNotificationAction(String buttonId) {
    if (buttonId == 'pause_all') {
      unawaited(pauseAllOwners());
    }
  }

  void handleNavigateToDownload() {
    if (_owners.contains(BackgroundDownloadOwner.rss) &&
        !_owners.contains(BackgroundDownloadOwner.http)) {
      final navigate = _navigationHandlers[BackgroundDownloadOwner.rss];
      if (navigate != null) {
        navigate();
        return;
      }
    }
    onNavigateToDownloadRequested?.call();
  }

  void addTaskDataCallback(void Function(Object) callback) {
    FlutterForegroundTask.addTaskDataCallback(callback);
  }

  void removeTaskDataCallback(void Function(Object) callback) {
    FlutterForegroundTask.removeTaskDataCallback(callback);
  }
}

class _OwnerProgress {
  const _OwnerProgress({
    required this.activeCount,
    required this.totalCount,
    required this.overallProgress,
    required this.speedText,
    this.bytesPerSecond,
  });
  final int activeCount;
  final int totalCount;
  final double overallProgress;
  final String speedText;
  final double? bytesPerSecond;
}

/// 后台任务回调（在独立 Isolate 中运行）
///
/// 注意：此回调主要用于保持服务存活和处理通知交互。
/// 实际下载逻辑在主 Isolate 中运行。
@pragma('vm:entry-point')
void _backgroundCallback() {
  FlutterForegroundTask.setTaskHandler(_DownloadTaskHandler());
}

class _DownloadTaskHandler extends TaskHandler {
  String? _session;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _session = await FlutterForegroundTask.getData<String>(
      key: _foregroundSessionKey,
    );
    debugPrint('BackgroundDownloadService: task handler started');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // eventAction 配置为 nothing，不会触发
  }

  @override
  void onNotificationButtonPressed(String id) {
    debugPrint('BackgroundDownloadService: notification button pressed: $id');
    FlutterForegroundTask.sendDataToMain({
      'action': 'button_pressed',
      'id': id,
    });
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.sendDataToMain({'action': 'navigate_to_download'});
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {
    // 前台服务通知通常不可划掉
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    FlutterForegroundTask.sendDataToMain({
      'action': 'service_destroyed',
      'session': _session,
      'isTimeout': isTimeout,
    });
    debugPrint(
      'BackgroundDownloadService: task handler destroyed (isTimeout: $isTimeout)',
    );
  }

  @override
  void onReceiveData(Object data) {
    debugPrint('BackgroundDownloadService: received data: $data');
  }
}
