import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/broadcast_slot.dart';

void main() {
  test('parses the relay index and skips malformed entries', () {
    final index = parseAirtimeIndex({
      'updated': '2026-10-13T00:59:42Z',
      'items': {
        '622288': {'t': '2026-10-01T12:30:00Z', 'p': 7, 'e': ''},
        '1': {'t': '2006-04-02T15:00:00Z', 'p': 7, 'e': '2006-09-24T15:00:00Z'},
        'x': {'t': '2026-10-01T12:30:00Z', 'p': 7, 'e': ''},
        '2': {'t': 'not a time'},
        '3': 'broken',
      },
    });

    expect(index.keys, unorderedEquals([622288, 1]));
    final slot = index[622288]!;
    expect(slot.start, DateTime.utc(2026, 10, 1, 12, 30));
    expect(slot.periodDays, 7);
    expect(slot.end, isNull);
    expect(index[1]!.end, DateTime.utc(2006, 9, 24, 15));
    expect(parseAirtimeIndex(null), isEmpty);
    expect(parseAirtimeIndex({'items': []}), isEmpty);
  });

  test('labels follow the local time zone', () {
    final slot = BroadcastSlot(
      start: DateTime.utc(2026, 10, 1, 12, 30),
      periodDays: 7,
    );
    final local = DateTime.utc(2026, 10, 1, 12, 30).toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    expect(slot.localTimeLabel, '$hh:$mm');
    expect(slot.localWeekday, local.weekday);
    expect(slot.localMinuteOfDay, local.hour * 60 + local.minute);
  });

  test('sorts the evening before a column ahead of that day', () {
    final slot = BroadcastSlot(
      start: DateTime(2026, 10, 7, 23, 30).toUtc(),
      periodDays: 7,
    );
    final local = slot.localStart;
    final minute = local.hour * 60 + local.minute;
    expect(slot.minuteInColumn(local.weekday), minute);
    final nextWeekday = local.weekday % 7 + 1;
    expect(slot.minuteInColumn(nextWeekday), minute - 24 * 60);
    final previousWeekday = (local.weekday + 5) % 7 + 1;
    expect(slot.minuteInColumn(previousWeekday), minute + 24 * 60);
  });
}
