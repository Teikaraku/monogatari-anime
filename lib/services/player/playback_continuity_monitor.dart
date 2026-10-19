/// Native EOF can mean a truncated HTTP response rather than the episode end.
/// Also detect a stopped media clock even when iOS does not emit buffering.
class PlaybackContinuityMonitor {
  PlaybackContinuityMonitor({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  Duration? _position;
  DateTime? _progressAt;
  bool _recovered = false;

  static bool prematureEnd(Duration position, Duration duration) =>
      duration > const Duration(seconds: 15) &&
      position < duration - const Duration(seconds: 10);

  bool update({
    required bool playing,
    required bool buffering,
    required bool completed,
    required Duration position,
    required Duration duration,
  }) {
    if (_recovered) return false;
    final now = _clock();
    if (completed && prematureEnd(position, duration)) {
      _recovered = true;
      return true;
    }
    if (!playing || completed || _position != position) {
      _position = position;
      _progressAt = now;
      return false;
    }
    _progressAt ??= now;
    if (position >= const Duration(seconds: 1) &&
        !buffering &&
        now.difference(_progressAt!) >= const Duration(seconds: 12)) {
      _recovered = true;
      return true;
    }
    return false;
  }
}
