import 'dart:async';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/metered_network_service.dart';
import 'package:kazumi/services/player/low_memory_mode.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:media_kit/media_kit.dart';
import 'adaptive_rebuffer_policy.dart';

class PlaybackCachePolicy {
  PlaybackCachePolicy({
    required bool Function() isLocalPlayback,
    required Player? Function() currentPlayer,
    bool Function()? isTorrentStream,
  }) : _isLocalPlayback = isLocalPlayback,
       _isTorrentStream = isTorrentStream ?? (() => false),
       _currentPlayer = currentPlayer;

  // Two MiB holds only a few seconds of typical HD video. A bounded forward
  // buffer absorbs segment latency without a 1.5 GiB memory reservation.
  static const int _lowMemoryBufferSize = 32 * 1024 * 1024;
  static const int _defaultBufferSize = 128 * 1024 * 1024;

  final bool Function() _isLocalPlayback;
  final bool Function() _isTorrentStream;
  final Player? Function() _currentPlayer;
  final AsyncSerialQueue _writes = AsyncSerialQueue();

  StreamSubscription<void>? _settingsSubscription;
  Timer? _bufferTimer;
  Player? _tunedPlayer;
  AdaptiveRebufferPolicy? _rebuffer;
  bool _prefetchSuspended = false;

  Future<void> setPrefetchSuspended(bool value) async {
    _prefetchSuspended = value;
    await apply();
  }

  bool get networkAutomatic =>
      LowMemoryMode.current == LowMemoryMode.auto &&
      !_isLocalPlayback() &&
      MeteredNetworkService.isMetered;

  int get bufferSize =>
      LowMemoryMode.current.isEnabled(
        isMetered: MeteredNetworkService.isMetered,
        isLocalPlayback: _isLocalPlayback(),
      )
      ? _lowMemoryBufferSize
      : _isTorrentStream()
      ? 32 * 1024 * 1024
      : _defaultBufferSize;

  void startWatching() {
    if (_settingsSubscription != null) {
      return;
    }
    _settingsSubscription = LowMemoryMode.watch().listen((_) => _onChanged());
    MeteredNetworkService.listenable.addListener(_onChanged);
  }

  void stopWatching() {
    _bufferTimer?.cancel();
    _bufferTimer = null;
    _tunedPlayer = null;
    _rebuffer = null;
    _prefetchSuspended = false;
    MeteredNetworkService.listenable.removeListener(_onChanged);
    unawaited(_settingsSubscription?.cancel());
    _settingsSubscription = null;
  }

  Future<void> apply() async {
    final player = _currentPlayer();
    if (player == null) {
      return;
    }
    try {
      final pp = player.platform as NativePlayer;
      // A stale player's initialization must not block its replacement's writes.
      await pp.waitForPlayerInitialization;
      await _writes.run(() async {
        if (!identical(_currentPlayer(), player)) {
          return;
        }
        final size = bufferSize.toString();
        await pp.setProperty('demuxer-max-bytes', size);
        await pp.setProperty(
          'demuxer-max-back-bytes',
          (bufferSize ~/ 4).toString(),
        );
        if (!_isLocalPlayback()) {
          _watchBuffer(player);
          await pp.setProperty('cache-on-disk', 'no');
          await pp.setProperty(
            'cache-secs',
            _prefetchSuspended
                ? '0'
                : _isTorrentStream()
                ? '90'
                : '60',
          );
          await pp.setProperty(
            'demuxer-readahead-secs',
            _prefetchSuspended ? '0' : '1',
          );
          await pp.setProperty('cache-pause', 'yes');
          await pp.setProperty('cache-pause-wait', '${_rebuffer!.waitSeconds}');
          await pp.setProperty('cache-pause-initial', 'yes');
        }
      });
    } catch (e) {
      KazumiLogger().w(
        'PlaybackCachePolicy: failed to apply demuxer cache size',
        error: e,
      );
    }
  }

  void _watchBuffer(Player player) {
    if (identical(_tunedPlayer, player)) return;
    _bufferTimer?.cancel();
    _tunedPlayer = player;
    final tuning = _rebuffer = AdaptiveRebufferPolicy(
      torrent: _isTorrentStream(),
    );
    _bufferTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!identical(_currentPlayer(), player) || _prefetchSuspended) return;
      final state = player.state;
      final wait = tuning.update(
        playing: state.playing && !state.completed,
        buffering: state.buffering,
        position: state.position,
      );
      if (wait == null) return;
      unawaited(
        _writes.run(() async {
          if (!identical(_currentPlayer(), player)) return;
          try {
            await (player.platform as NativePlayer).setProperty(
              'cache-pause-wait',
              '$wait',
            );
          } catch (_) {}
        }),
      );
    });
  }

  void _onChanged() {
    unawaited(apply());
  }
}
