/// When a subject airs, from bangumi-data (served by the relay at
/// /meta/airtime.json): the first Japanese broadcast and its repeat period.
class BroadcastSlot {
  const BroadcastSlot({
    required this.start,
    required this.periodDays,
    this.end,
  });

  /// First broadcast, in UTC.
  final DateTime start;

  /// Days between broadcasts; 7 for weekly shows, 0 when unknown.
  final int periodDays;

  /// Last broadcast in UTC, or null while airing.
  final DateTime? end;

  static BroadcastSlot? fromJson(Object? json) {
    if (json is! Map) return null;
    final start = DateTime.tryParse('${json['t'] ?? ''}');
    if (start == null) return null;
    final period = json['p'];
    final endText = '${json['e'] ?? ''}';
    return BroadcastSlot(
      start: start.toUtc(),
      periodDays: period is num ? period.toInt() : 0,
      end: endText.isEmpty ? null : DateTime.tryParse(endText)?.toUtc(),
    );
  }

  DateTime get localStart => start.toLocal();

  /// ISO weekday of the broadcast in the device's time zone.
  int get localWeekday => localStart.weekday;

  /// Minutes after local midnight.
  int get localMinuteOfDay => localStart.hour * 60 + localStart.minute;

  /// "20:30" in the device's time zone.
  String get localTimeLabel {
    final local = localStart;
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  /// Sort key within the timetable column of ISO [weekday]: minutes from that
  /// day's midnight, negative when the show airs locally the evening before.
  int minuteInColumn(int weekday) {
    final shift = (localWeekday - weekday + 7) % 7;
    final dayOffset = switch (shift) { 0 => 0, 1 => 1, 6 => -1, _ => 0 };
    return dayOffset * 24 * 60 + localMinuteOfDay;
  }
}

/// Parses the relay's index: `{"items": {"<bangumi id>": {t, p, e}}}`.
Map<int, BroadcastSlot> parseAirtimeIndex(Object? json) {
  final items = json is Map ? json['items'] : null;
  if (items is! Map) return const {};
  final index = <int, BroadcastSlot>{};
  items.forEach((key, value) {
    final id = int.tryParse('$key');
    final slot = BroadcastSlot.fromJson(value);
    if (id != null && slot != null) index[id] = slot;
  });
  return index;
}
