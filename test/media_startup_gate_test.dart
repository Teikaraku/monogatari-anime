import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/automatic_playback_runner.dart';
import 'package:kazumi/services/player/media_startup_gate.dart';

void main() {
  test(
    'fatal error permits fallback while native initialization remains pending',
    () async {
      for (final lateFailure in [false, true]) {
        final initialization = Completer<bool>();
        final failure = Completer<bool>();
        final opening = Completer<void>();
        final ready = <String>[];
        final runner = AutomaticPlaybackRunner<String>(
          open: (candidate, _) {
            if (candidate == 'priority') {
              opening.complete();
              return waitForMediaInitialization(
                initialization: initialization.future,
                interrupted: failure.future,
                isCurrent: () => true,
              );
            }
            return waitForMediaInitialization(
              initialization: Future.value(true),
              interrupted: Completer<bool>().future,
              isCurrent: () => true,
            );
          },
          stop: () async {},
          onAttempt: (_) {},
          onReady: ready.add,
          onExhausted: () => fail('the backup initializes successfully'),
          currentOffset: () => 0,
        );
        final result = runner.start(
          Stream.fromIterable(['priority', 'backup']),
        );
        await opening.future;
        failure.complete(false);
        expect(await result.timeout(const Duration(seconds: 1)), isTrue);
        expect(initialization.isCompleted, isFalse);
        expect(ready, ['backup']);
        if (lateFailure) {
          initialization.completeError(StateError('late native failure'));
        } else {
          initialization.complete(true);
        }
        await Future<void>.delayed(Duration.zero);
        expect(ready, ['backup']);
        await runner.cancel();
      }
    },
  );

  test('a stale initialization cannot report readiness', () async {
    final initialization = Completer<bool>();
    var current = true;
    final result = waitForMediaInitialization(
      initialization: initialization.future,
      interrupted: Completer<bool>().future,
      isCurrent: () => current,
    );
    current = false;
    initialization.complete(true);
    expect(await result, isFalse);
  });

  test('native initialization failure returns a failed attempt', () async {
    expect(
      await waitForMediaInitialization(
        initialization: Future.error(
          StateError('native initialization failed'),
        ),
        interrupted: Completer<bool>().future,
        isCurrent: () => true,
      ),
      isFalse,
    );
  });

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
