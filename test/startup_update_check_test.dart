import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/update/startup_update_check.dart';

void main() {
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
