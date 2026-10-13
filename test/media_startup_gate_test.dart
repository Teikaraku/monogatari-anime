import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/automatic_playback_runner.dart';
import 'package:kazumi/services/player/media_startup_gate.dart';

void main() {
  test('native frame output is required before reporting ready', () async {
    final frame = Completer<void>();
    final interrupted = Completer<bool>();
    var completed = false;
    final result = waitForFirstVideoFrame(
      firstFrame: frame.future,
      interrupted: interrupted.future,
      isCurrent: () => true,
    );
    result.then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    frame.complete();
    expect(await result, isTrue);
  });

  test(
    'a missing frame can time out and permit the backup source to play',
    () async {
      final firstFrame = Completer<void>();
      final failure = Completer<bool>();
      final opening = Completer<void>();
      final ready = <String>[];
      final runner = AutomaticPlaybackRunner<String>(
        open: (candidate, offset) {
          if (candidate == 'primary') {
            opening.complete();
            return waitForFirstVideoFrame(
              firstFrame: firstFrame.future,
              interrupted: failure.future,
              isCurrent: () => true,
            );
          }
          return waitForFirstVideoFrame(
            firstFrame: Future.value(),
            interrupted: Completer<bool>().future,
            isCurrent: () => true,
          );
        },
        stop: () async {},
        onAttempt: (_) {},
        onReady: ready.add,
        onExhausted: () => fail('the backup has a frame'),
        currentOffset: () => 0,
      );
      addTearDown(runner.cancel);
      final started = runner.start(Stream.fromIterable(['primary', 'backup']));
      await opening.future;
      failure.complete(false);
      expect(await started, isTrue);
      expect(ready, ['backup']);
      firstFrame.complete();
      await Future<void>.delayed(Duration.zero);
      expect(ready, ['backup']);
    },
  );

  test('a frame belonging to a cancelled player cannot become ready', () async {
    final frame = Completer<void>();
    var current = true;
    final result = waitForFirstVideoFrame(
      firstFrame: frame.future,
      interrupted: Completer<bool>().future,
      isCurrent: () => current,
    );
    current = false;
    frame.complete();
    expect(await result, isFalse);
  });

  test(
    'native output failure is a failed candidate rather than an uncaught error',
    () async {
      expect(
        await waitForFirstVideoFrame(
          firstFrame: Future.error(StateError('video output failed')),
          interrupted: Completer<bool>().future,
          isCurrent: () => true,
        ),
        isFalse,
      );
    },
  );
}
