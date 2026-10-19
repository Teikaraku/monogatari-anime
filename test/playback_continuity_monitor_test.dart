import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/playback_continuity_monitor.dart';

void main() {
  test('a truncated stream is recovered, a normal episode end is not', () {
    expect(
      PlaybackContinuityMonitor.prematureEnd(
        const Duration(seconds: 7),
        const Duration(minutes: 24),
      ),
      isTrue,
    );
    expect(
      PlaybackContinuityMonitor.prematureEnd(
        const Duration(minutes: 24),
        const Duration(minutes: 24),
      ),
      isFalse,
    );
    expect(
      PlaybackContinuityMonitor.prematureEnd(Duration.zero, Duration.zero),
      isFalse,
    );
  });
  test(
    'stopped clock without a buffering event recovers once while user pauses are respected',
    () {
      var now = DateTime(2026);
      final monitor = PlaybackContinuityMonitor(clock: () => now);
      bool update({
        bool playing = true,
        bool buffering = false,
        int position = 3,
      }) => monitor.update(
        playing: playing,
        buffering: buffering,
        completed: false,
        position: Duration(seconds: position),
        duration: const Duration(minutes: 24),
      );
      expect(update(), isFalse);
      now = now.add(const Duration(seconds: 20));
      expect(update(playing: false), isFalse);
      expect(update(), isFalse);
      now = now.add(const Duration(seconds: 11));
      expect(update(), isFalse);
      now = now.add(const Duration(seconds: 1));
      expect(update(), isTrue);
      expect(update(), isFalse);
    },
  );
  test(
    'ordinary buffering and seek progress do not count as a silent stall',
    () {
      var now = DateTime(2026);
      final monitor = PlaybackContinuityMonitor(clock: () => now);
      bool update(int seconds, bool buffering) => monitor.update(
        playing: true,
        buffering: buffering,
        completed: false,
        position: Duration(seconds: seconds),
        duration: const Duration(minutes: 24),
      );
      update(1, false);
      now = now.add(const Duration(seconds: 20));
      expect(update(1, true), isFalse);
      expect(update(80, false), isFalse);
    },
  );
}
