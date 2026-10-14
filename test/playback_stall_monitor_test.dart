import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/playback_stall_monitor.dart';

void main() {
  test('frequent short stalls trigger exactly one recovery', () {
    var now = DateTime(2026);
    final monitor = PlaybackStallMonitor(clock: () => now);
    for (var i = 0; i < 3; i++) {
      monitor.update(playing: true, buffering: true);
      now = now.add(const Duration(seconds: 2));
      monitor.update(playing: true, buffering: false);
      expect(monitor.shouldRecover, isFalse);
      now = now.add(const Duration(seconds: 2));
    }
    monitor.update(playing: true, buffering: true);
    now = now.add(const Duration(seconds: 2));
    expect(monitor.shouldRecover, isTrue);
    expect(monitor.shouldRecover, isFalse);
  });

  test('pauses and old stalls do not penalize an otherwise healthy source', () {
    var now = DateTime(2026);
    final monitor = PlaybackStallMonitor(clock: () => now);
    for (var i = 0; i < 5; i++) {
      monitor.update(playing: true, buffering: true);
      now = now.add(const Duration(seconds: 2));
      monitor.update(playing: false, buffering: true);
      now = now.add(const Duration(seconds: 40));
    }
    monitor.update(playing: true, buffering: true);
    now = now.add(const Duration(seconds: 2));
    expect(monitor.shouldRecover, isFalse);
  });
}
