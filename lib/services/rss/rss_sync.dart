import 'dart:convert';

/// A subscription as other devices see it. A deletion stays as an entry so an
/// offline device cannot bring a removed subscription back.
class RssSyncEntry {
  const RssSyncEntry({
    required this.id,
    required this.updatedAt,
    required this.deviceId,
    this.subscription,
  });

  final String id;

  /// Milliseconds since the epoch of the last change.
  final int updatedAt;
  final String deviceId;

  /// The subscription's JSON without refresh state; null once deleted.
  final Map<String, dynamic>? subscription;

  bool get deleted => subscription == null;

  int compareTo(RssSyncEntry other) {
    final time = updatedAt.compareTo(other.updatedAt);
    if (time != 0) return time;
    final device = deviceId.compareTo(other.deviceId);
    if (device != 0) return device;
    return (deleted ? 1 : 0).compareTo(other.deleted ? 1 : 0);
  }

  bool sameVersion(RssSyncEntry other) =>
      updatedAt == other.updatedAt &&
      deviceId == other.deviceId &&
      deleted == other.deleted;

  Map<String, Object?> toJson() => {
    'id': id,
    'updatedAt': updatedAt,
    'deviceId': deviceId,
    'subscription': subscription,
  };

  factory RssSyncEntry.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Invalid RSS sync entry');
    final id = value['id'];
    final updatedAt = value['updatedAt'];
    final deviceId = value['deviceId'];
    final subscription = value['subscription'];
    if (id is! String ||
        id.isEmpty ||
        updatedAt is! int ||
        updatedAt < 0 ||
        deviceId is! String ||
        deviceId.isEmpty ||
        (subscription != null && subscription is! Map)) {
      throw const FormatException('Invalid RSS sync entry');
    }
    return RssSyncEntry(
      id: id,
      updatedAt: updatedAt,
      deviceId: deviceId,
      subscription: subscription == null
          ? null
          : Map<String, dynamic>.from(subscription as Map),
    );
  }
}

/// The subtitle group picked for playing a show.
class RssSyncSelection {
  const RssSyncSelection({
    required this.bangumiId,
    required this.subscriptionId,
    required this.updatedAt,
    required this.deviceId,
  });

  final int bangumiId;
  final String subscriptionId;
  final int updatedAt;
  final String deviceId;

  int compareTo(RssSyncSelection other) {
    final time = updatedAt.compareTo(other.updatedAt);
    if (time != 0) return time;
    return deviceId.compareTo(other.deviceId);
  }

  bool sameVersion(RssSyncSelection other) =>
      updatedAt == other.updatedAt &&
      deviceId == other.deviceId &&
      subscriptionId == other.subscriptionId;

  Map<String, Object> toJson() => {
    'bangumiId': bangumiId,
    'subscriptionId': subscriptionId,
    'updatedAt': updatedAt,
    'deviceId': deviceId,
  };

  factory RssSyncSelection.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Invalid RSS selection');
    final bangumiId = value['bangumiId'];
    final subscriptionId = value['subscriptionId'];
    final updatedAt = value['updatedAt'];
    final deviceId = value['deviceId'];
    if (bangumiId is! int ||
        bangumiId <= 0 ||
        subscriptionId is! String ||
        updatedAt is! int ||
        deviceId is! String ||
        deviceId.isEmpty) {
      throw const FormatException('Invalid RSS selection');
    }
    return RssSyncSelection(
      bangumiId: bangumiId,
      subscriptionId: subscriptionId,
      updatedAt: updatedAt,
      deviceId: deviceId,
    );
  }
}

/// Subscriptions and playback picks of every device; the latest change wins.
class RssSyncState {
  RssSyncState({
    Iterable<RssSyncEntry> entries = const [],
    Iterable<RssSyncSelection> selections = const [],
  }) : entries = Map.unmodifiable(
         _latest<String, RssSyncEntry>(entries, (e) => e.id),
       ),
       selections = Map.unmodifiable(
         _latest<int, RssSyncSelection>(selections, (s) => s.bangumiId),
       );

  final Map<String, RssSyncEntry> entries;
  final Map<int, RssSyncSelection> selections;

  RssSyncState merge(RssSyncState other) => RssSyncState(
    entries: [...entries.values, ...other.entries.values],
    selections: [...selections.values, ...other.selections.values],
  );

  String encode() {
    final sortedEntries = entries.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final sortedSelections = selections.values.toList()
      ..sort((a, b) => a.bangumiId.compareTo(b.bangumiId));
    return jsonEncode({
      'version': 1,
      'entries': [for (final entry in sortedEntries) entry.toJson()],
      'selections': [
        for (final selection in sortedSelections) selection.toJson(),
      ],
    });
  }

  factory RssSyncState.decode(String source) {
    final value = jsonDecode(source);
    if (value is! Map ||
        value['version'] != 1 ||
        value['entries'] is! List ||
        value['selections'] is! List) {
      throw const FormatException('Invalid RSS sync document');
    }
    return RssSyncState(
      entries: (value['entries'] as List).map(RssSyncEntry.fromJson),
      selections: (value['selections'] as List).map(RssSyncSelection.fromJson),
    );
  }

  static Map<K, V> _latest<K, V extends Object>(
    Iterable<V> values,
    K Function(V) key,
  ) {
    final result = <K, V>{};
    for (final value in values) {
      final previous = result[key(value)];
      if (previous == null || _compare(value, previous) > 0) {
        result[key(value)] = value;
      }
    }
    return result;
  }

  static int _compare(Object a, Object b) => switch ((a, b)) {
    (RssSyncEntry a, RssSyncEntry b) => a.compareTo(b),
    (RssSyncSelection a, RssSyncSelection b) => a.compareTo(b),
    _ => 0,
  };
}
