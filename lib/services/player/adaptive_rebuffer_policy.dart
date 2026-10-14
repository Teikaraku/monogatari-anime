/// Start promptly on a healthy link, but accumulate a longer runway after
/// underruns. User pauses never count as stalls or reset the recovered runway.
class AdaptiveRebufferPolicy {
  AdaptiveRebufferPolicy({required this.torrent, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final bool torrent;
  final DateTime Function() _clock;
  Duration? _position;
  DateTime? _progressAt;
  DateTime? _smoothAt;
  bool _stall = false;
  int _level = 0;

  int get waitSeconds =>
      torrent ? [3, 8, 15, 20][_level] : [1, 3, 6, 10][_level];

  int? update({
    required bool playing,
    required bool buffering,
    required Duration position,
  }) {
    final now = _clock();
    final previous = waitSeconds;
    if (!playing) {
      _position = position;
      _progressAt = now;
      _smoothAt = null;
      _stall = false;
      return null;
    }
    if (_position != position) {
      _progressAt = now;
      _position = position;
    }
    _progressAt ??= now;
    // Some native backends do not report buffering while waiting on a local
    // torrent HTTP read. A stopped clock after playback began is also a stall.
    final stalled =
        position >= const Duration(seconds: 1) &&
        (buffering ||
            now.difference(_progressAt!) >= const Duration(seconds: 2));
    if (stalled) {
      if (!_stall) _level = (_level + 1).clamp(0, 3);
      _stall = true;
      _smoothAt = null;
    } else {
      _stall = false;
      _smoothAt ??= now;
      if (now.difference(_smoothAt!) >= const Duration(minutes: 2) &&
          _level > 0) {
        _level--;
        _smoothAt = now;
      }
    }
    return previous == waitSeconds ? null : waitSeconds;
  }
}
