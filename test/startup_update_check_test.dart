import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/update/startup_update_check.dart';

void main() {
  test('transient startup errors retry within one shared check and report one update', () async {
    final session = StartupUpdateCheck();
    var calls = 0;
    var dialogs = 0;
    Future<void> check() async {
      if (++calls < 3) throw TimeoutException('network warming up');
      dialogs++;
    }
    await Future.wait(List.generate(3, (_) => session.run(
      checkForUpdate: check, delay: Duration.zero,
      shouldRetry: (error) => error is TimeoutException,
      retryDelays: const [Duration.zero, Duration.zero],
    )));
    await session.run(checkForUpdate: check, delay: Duration.zero);
    expect(calls, 3);
    expect(dialogs, 1);
  });

  test('permanent errors are not retried', () async {
    var calls = 0;
    await expectLater(StartupUpdateCheck().run(
      delay: Duration.zero,
      shouldRetry: (error) => error is TimeoutException,
      checkForUpdate: () async { calls++; throw const FormatException('bad metadata'); },
    ), throwsFormatException);
    expect(calls, 1);
  });
  test(
    'concurrent and repeated startup calls only check once per session',
    () async {
      final session = StartupUpdateCheck();
      final ready = Completer<void>();
      var count = 0;
      Future<void> check() async {
        count++;
        await ready.future;
      }

      final first = session.run(checkForUpdate: check, delay: Duration.zero);
      final second = session.run(checkForUpdate: check, delay: Duration.zero);
      expect(identical(first, second), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(count, 1);
      ready.complete();
      await first;
      await session.run(checkForUpdate: check, delay: Duration.zero);
      expect(count, 1);
      await StartupUpdateCheck().run(
        checkForUpdate: check,
        delay: Duration.zero,
      );
      expect(count, 2);
    },
  );

  test('startup check survives the scheduling page being removed', () async {
    var pageMounted = true;
    var checked = false;
    final pending = StartupUpdateCheck().run(
      delay: Duration.zero,
      checkForUpdate: () async {
        expect(pageMounted, isFalse);
        checked = true;
      },
    );
    pageMounted = false;
    await pending;
    expect(checked, isTrue);
  });
}
