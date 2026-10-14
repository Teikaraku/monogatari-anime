import 'dart:async';
import 'dart:math';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/rss/rss_subscription_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';

/// Keeps RSS subscriptions in step across devices through WebDAV: once at
/// startup and shortly after every change made here.
class RssSyncService {
  RssSyncService(this._subscriptions, this._webDav);

  final RssSubscriptionService _subscriptions;
  final WebDav _webDav;
  StreamSubscription<void>? _edits;
  Timer? _timer;

  void start() {
    if (_edits != null) return;
    _edits = _subscriptions.localEdits.listen((_) => _schedule());
    unawaited(syncIfEnabled());
  }

  void _schedule() {
    _timer?.cancel();
    if (!_webDav.isRssSyncEnabled) return;
    _timer = Timer(const Duration(seconds: 2), () {
      unawaited(syncIfEnabled());
    });
  }

  Future<void> sync() async {
    _timer?.cancel();
    if (!_webDav.isRssSyncEnabled) return;
    final deviceId = await _deviceId();
    await _webDav.syncRssSubscriptions(
      deviceId: deviceId,
      merge: (remote) => _subscriptions.mergeSyncState(remote, deviceId),
    );
  }

  Future<void> syncIfEnabled() async {
    try {
      await sync();
    } catch (e, stackTrace) {
      KazumiLogger().w(
        'WebDav: automatic RSS sync failed; keeping local subscriptions',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  static Future<String> _deviceId() async {
    var deviceId = GStorage.getSetting(SettingsKeys.rssSyncDeviceId);
    if (deviceId.isEmpty) {
      final random = Random.secure();
      deviceId = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await GStorage.putSetting(SettingsKeys.rssSyncDeviceId, deviceId);
    }
    return deviceId;
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _edits?.cancel();
    _edits = null;
  }
}
