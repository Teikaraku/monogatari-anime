/// Recognize repeated short stalls that never reach a single-stall timeout.
class PlaybackStallMonitor {
  PlaybackStallMonitor({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  final _intervals = <(DateTime, DateTime)>[];
  DateTime? _started;
  bool _active = false;
  bool _recovered = false;

  void update({required bool playing, required bool buffering}) {
    final now = _clock();
    if (!playing) {
      _intervals.clear();
      _started = null;
      _active = false;
      return;
    }
    _active = true;
    if (buffering) {
      _started ??= now;
    } else if (_started != null) {
      _intervals.add((_started!, now));
      _started = null;
    }
    _intervals.removeWhere(
      (interval) => now.difference(interval.$2) > const Duration(seconds: 30),
    );
  }

  bool get shouldRecover {
    if (!_active || _recovered || _started == null) return false;
    final now = _clock();
    final cutoff = now.subtract(const Duration(seconds: 30));
    final intervals = [
      ..._intervals.where((interval) => interval.$2.isAfter(cutoff)),
      (_started!, now),
    ];
    final blocked = intervals.fold<Duration>(
      Duration.zero,
      (duration, interval) =>
          duration +
          interval.$2.difference(
            interval.$1.isBefore(cutoff) ? cutoff : interval.$1,
          ),
    );
    if (intervals.length >= 4 && blocked >= const Duration(seconds: 8)) {
      _recovered = true;
      return true;
    }
    return false;
  }
}
