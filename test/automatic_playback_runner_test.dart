import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/automatic_playback_runner.dart';

void main() {
  test('native TCP read errors from real logs trigger fallback', () {
    for (final error in ['tcp: ffurl_read returned 0xffffffc4',
        'tcp: Connection to tcp://video.test:443 failed: Connection refused']) {
      expect(AutomaticPlaybackRunner.isFatalMediaError(error), isTrue);
    }
  });
  const providers = ['1080资源站', '暴风', '量子'];

  test(
    'tries providers in order and stops after the first playable one',
    () async {
      final attempts = <String>[];
      final ready = <String>[];
      final offsets = <int>[];
      var stops = 0;
      var exhausted = 0;
      final runner = AutomaticPlaybackRunner<String>(
        open: (candidate, offset) async {
          offsets.add(offset);
          return candidate == '量子';
        },
        stop: () async => stops++,
        onAttempt: attempts.add,
        onReady: ready.add,
        onExhausted: () => exhausted++,
        currentOffset: () => 99,
      );
      addTearDown(runner.cancel);

      expect(
        await runner.start(Stream.fromIterable(providers), offset: 12),
        isTrue,
      );
      expect(attempts, ['1080资源站', '暴风', '量子']);
      expect(ready, ['量子']);
      expect(offsets, [12, 12, 12]);
      expect(stops, 3);
      expect(exhausted, 0);
    },
  );

  test(
    'a failed player initialization still tries the next provider',
    () async {
      final attempts = <String>[];
      final ready = <String>[];
      var exhausted = 0;
      final runner = AutomaticPlaybackRunner<String>(
        open: (candidate, _) async {
          if (candidate == '1080资源站') throw StateError('failed to open media');
          return true;
        },
        stop: () async {},
        onAttempt: attempts.add,
        onReady: ready.add,
        onExhausted: () => exhausted++,
        currentOffset: () => 0,
      );
      addTearDown(runner.cancel);

      expect(await runner.start(Stream.fromIterable(providers)), isTrue);
      expect(attempts, ['1080资源站', '暴风']);
      expect(ready, ['暴风']);
      expect(exhausted, 0);
    },
  );

  test('runtime recovery continues at the current playback position', () async {
    final opened = <(String, int)>[];
    final ready = <String>[];
    var position = 0;
    final runner = AutomaticPlaybackRunner<String>(
      open: (candidate, offset) async {
        opened.add((candidate, offset));
        return true;
      },
      stop: () async {},
      onAttempt: (_) {},
      onReady: ready.add,
      onExhausted: () => fail('a usable backup is still available'),
      currentOffset: () => position,
    );
    addTearDown(runner.cancel);

    expect(
      await runner.start(Stream.fromIterable(providers), offset: 40),
      isTrue,
    );
    position = 287;
    expect(await runner.recover(), isTrue);
    expect(opened, [('1080资源站', 40), ('暴风', 287)]);
    expect(ready, ['1080资源站', '暴风']);
  });

  test('exhaustion terminates without looping or notifying twice', () async {
    final attempts = <String>[];
    var exhausted = 0;
    final runner = AutomaticPlaybackRunner<String>(
      open: (_, _) async => false,
      stop: () async {},
      onAttempt: attempts.add,
      onReady: (_) => fail('no provider is playable'),
      onExhausted: () => exhausted++,
      currentOffset: () => 17,
    );
    addTearDown(runner.cancel);

    expect(await runner.start(Stream.fromIterable(providers)), isFalse);
    expect(await runner.recover(), isFalse);
    expect(await runner.recover(), isFalse);
    expect(attempts, providers);
    expect(exhausted, 1);
  });

  test('an empty or failed candidate stream terminates once', () async {
    for (final candidates in [
      const Stream<String>.empty(),
      Stream<String>.error(StateError('API unavailable')),
    ]) {
      var exhausted = 0;
      final runner = AutomaticPlaybackRunner<String>(
        open: (_, _) async => fail('there is no candidate to open'),
        stop: () async => fail('there is no candidate to stop for'),
        onAttempt: (_) => fail('there is no candidate to attempt'),
        onReady: (_) => fail('there is no candidate to play'),
        onExhausted: () => exhausted++,
        currentOffset: () => 0,
      );

      expect(await runner.start(candidates), isFalse);
      expect(await runner.recover(), isFalse);
      expect(exhausted, 1);
      await runner.cancel();
    }
  });

  test('cancel prevents a late open from notifying the new episode', () async {
    final opening = Completer<void>();
    final result = Completer<bool>();
    final ready = <String>[];
    var exhausted = 0;
    final runner = AutomaticPlaybackRunner<String>(
      open: (_, _) {
        opening.complete();
        return result.future;
      },
      stop: () async {},
      onAttempt: (_) {},
      onReady: ready.add,
      onExhausted: () => exhausted++,
      currentOffset: () => 0,
    );
    addTearDown(runner.cancel);

    final started = runner.start(Stream.fromIterable(['旧剧集']));
    await opening.future;
    await runner.cancel();
    result.complete(true);

    expect(await started, isFalse);
    expect(ready, isEmpty);
    expect(exhausted, 0);
    expect(await runner.recover(), isFalse);
  });

  test('cancel during player shutdown prevents the obsolete open', () async {
    final stopping = Completer<void>();
    final stopped = Completer<void>();
    final runner = AutomaticPlaybackRunner<String>(
      open: (_, _) async => fail('cancelled playback must never open'),
      stop: () {
        stopping.complete();
        return stopped.future;
      },
      onAttempt: (_) => fail('cancelled playback must never attempt'),
      onReady: (_) => fail('cancelled playback must never become ready'),
      onExhausted: () => fail('cancelled playback must not report exhaustion'),
      currentOffset: () => 0,
    );
    addTearDown(runner.cancel);

    final started = runner.start(Stream.fromIterable(['旧剧集']));
    await stopping.future;
    await runner.cancel();
    stopped.complete();
    expect(await started, isFalse);
  });

  test(
    'repeated recovery events cannot open concurrent backup providers',
    () async {
      final recovering = Completer<void>();
      final recovered = Completer<bool>();
      final opened = <(String, int)>[];
      final ready = <String>[];
      final runner = AutomaticPlaybackRunner<String>(
        open: (candidate, offset) async {
          opened.add((candidate, offset));
          if (candidate == '暴风') {
            recovering.complete();
            return recovered.future;
          }
          return true;
        },
        stop: () async {},
        onAttempt: (_) {},
        onReady: ready.add,
        onExhausted: () => fail('a usable backup is still available'),
        currentOffset: () => 190,
      );
      addTearDown(runner.cancel);

      expect(await runner.start(Stream.fromIterable(providers)), isTrue);
      final firstRecovery = runner.recover();
      await recovering.future;
      expect(await runner.recover(), isFalse);
      expect(opened, [('1080资源站', 0), ('暴风', 190)]);

      recovered.complete(true);
      expect(await firstRecovery, isTrue);
      expect(ready, ['1080资源站', '暴风']);
    },
  );

  test('concurrent starts only open and publish the latest episode', () async {
    final attempts = <String>[];
    final ready = <String>[];
    final runner = AutomaticPlaybackRunner<String>(
      open: (_, _) async => true,
      stop: () async {},
      onAttempt: attempts.add,
      onReady: ready.add,
      onExhausted: () => fail('the latest episode has a playable provider'),
      currentOffset: () => 0,
    );
    addTearDown(runner.cancel);

    final obsolete = runner.start(Stream.fromIterable(['旧剧集']));
    final latest = runner.start(Stream.fromIterable(['新剧集']));
    expect(await obsolete, isFalse);
    expect(await latest, isTrue);
    expect(attempts, ['新剧集']);
    expect(ready, ['新剧集']);
  });

  test('native cleanup failure does not discard a usable fallback', () async {
    final opened = <String>[];
    var cleanups = 0;
    final runner = AutomaticPlaybackRunner<String>(
      open: (candidate, _) async {
        opened.add(candidate);
        return true;
      },
      stop: () async {
        cleanups++;
        if (cleanups == 2) throw StateError('audio session cleanup failed');
      },
      onAttempt: (_) {},
      onReady: (_) {},
      onExhausted: () => fail('a usable backup remains'),
      currentOffset: () => 42,
    );
    addTearDown(runner.cancel);
    expect(await runner.start(Stream.fromIterable(providers)), isTrue);
    expect(await runner.recover(), isTrue);
    expect(opened, ['1080资源站', '暴风']);
  });
}
