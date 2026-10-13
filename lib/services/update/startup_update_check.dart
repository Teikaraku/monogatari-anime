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
  }) {
    return _check ??= Future<void>.delayed(delay).then((_) => checkForUpdate());
  }
}
