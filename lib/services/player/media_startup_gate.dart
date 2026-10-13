import 'dart:async';

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
