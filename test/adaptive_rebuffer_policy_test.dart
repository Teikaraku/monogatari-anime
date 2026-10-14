import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/adaptive_rebuffer_policy.dart';

void main() {
  test(
    'RSS short underruns accumulate a bounded runway across pause/resume',
    () {
      var now = DateTime(2026);
      final policy = AdaptiveRebufferPolicy(torrent: true, clock: () => now);
      int? update(int seconds, {bool buffering = false, bool playing = true}) =>
          policy.update(
            playing: playing,
            buffering: buffering,
            position: Duration(seconds: seconds),
          );
      expect(policy.waitSeconds, 3);
      update(0, buffering: true);
      expect(policy.waitSeconds, 3); // Startup is not a failed playback burst.
      update(2);
      expect(update(2, buffering: true), 8);
      expect(update(2, buffering: true), isNull);
      update(2, playing: false);
      update(3);
      expect(update(3, buffering: true), 15);
      update(4);
      expect(update(4, buffering: true), 20);
      update(5);
      update(5, buffering: true);
      expect(policy.waitSeconds, 20);
    },
  );
  test(
    'iOS stopped clock raises the buffer target without a buffering event',
    () {
      var now = DateTime(2026);
      final policy = AdaptiveRebufferPolicy(torrent: true, clock: () => now);
      policy.update(
        playing: true,
        buffering: false,
        position: const Duration(seconds: 2),
      );
      now = now.add(const Duration(seconds: 2));
      expect(
        policy.update(
          playing: true,
          buffering: false,
          position: const Duration(seconds: 2),
        ),
        8,
      );
      now = now.add(const Duration(seconds: 20));
      expect(
        policy.update(
          playing: false,
          buffering: false,
          position: const Duration(seconds: 2),
        ),
        isNull,
      );
      expect(policy.waitSeconds, 8);
    },
  );
  test('healthy playback gradually restores faster startup policy', () {
    var now = DateTime(2026);
    final policy = AdaptiveRebufferPolicy(torrent: false, clock: () => now);
    policy.update(
      playing: true,
      buffering: true,
      position: const Duration(seconds: 2),
    );
    expect(policy.waitSeconds, 3);
    policy.update(
      playing: true,
      buffering: false,
      position: const Duration(seconds: 3),
    );
    now = now.add(const Duration(minutes: 2));
    expect(
      policy.update(
        playing: true,
        buffering: false,
        position: const Duration(seconds: 123),
      ),
      1,
    );
  });
}
