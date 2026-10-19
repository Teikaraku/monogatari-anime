import 'dart:async';

const startupUpdateCheckDelay = Duration(milliseconds: 500);

/// One automatic check per application session, independent of route lifetime.
/// A new process gets a new instance, so dismissing an update only postpones it
/// until the next launch. Manual checks remain independent.
class StartupUpdateCheck {
  Future<void>? _check;

  Future<void> run({
    required Future<void> Function() checkForUpdate,
    Duration delay = startupUpdateCheckDelay,
    bool Function(Object error)? shouldRetry,
    List<Duration> retryDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 6),
    ],
  }) {
    return _check ??= _run(checkForUpdate, delay, shouldRetry, retryDelays);
  }

  Future<void> _run(
    Future<void> Function() check,
    Duration delay,
    bool Function(Object)? shouldRetry,
    List<Duration> retryDelays,
  ) async {
    await Future<void>.delayed(delay);
    for (var attempt = 0; ; attempt++) {
      try {
        await check();
        return;
      } catch (error) {
        if (attempt >= retryDelays.length || shouldRetry?.call(error) != true)
          rethrow;
        await Future<void>.delayed(retryDelays[attempt]);
      }
    }
  }
}
