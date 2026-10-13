import 'dart:async';

/// A fatal media error can arrive while native initialization is still
/// pending. Let the existing startup timeout/error signal fail that attempt
/// immediately; the caller stops its owned player before opening a backup.
Future<bool> waitForMediaInitialization({
  required Future<bool> initialization,
  required Future<bool> interrupted,
  required bool Function() isCurrent,
}) async {
  final initialized = await Future.any<bool>([
    initialization.then(
      (value) => value && isCurrent(),
      onError: (Object error, StackTrace stackTrace) => false,
    ),
    interrupted.then(
      (_) => false,
      onError: (Object error, StackTrace stackTrace) => false,
    ),
  ]);
  return initialized && isCurrent();
}

/// Dimensions and duration can exist before a decoder produces a frame.
/// Wait for native output while letting an error, timeout or cancellation win.
Future<bool> waitForFirstVideoFrame({
  required Future<void> firstFrame,
  required Future<bool> interrupted,
  required bool Function() isCurrent,
}) async {
  final ready = await Future.any<bool>([
    firstFrame.then(
      (_) => isCurrent(),
      onError: (Object error, StackTrace stackTrace) => false,
    ),
    interrupted,
  ]);
  return ready && isCurrent();
}
