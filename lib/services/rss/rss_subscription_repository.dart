import 'package:hive_ce/hive.dart';

import 'rss_models.dart';

/// When a subscription or a playback pick last changed, for sync. A null
/// device is this one.
typedef RssSyncStamp = ({int at, String? device, bool deleted});

class RssStoredState {
  const RssStoredState({
    this.subscriptions = const [],
    this.releases = const [],
    this.selected = const {},
    this.viewed = const {},
    this.stamps = const {},
    this.selectionStamps = const {},
    this.unreadableSubscriptions = const [],
    this.unreadableReleases = const [],
  });
  final List<RssSubscription> subscriptions;
  final List<RssRelease> releases;
  final Map<int, String> selected;

  /// When each show's resources were last opened, by Bangumi id.
  final Map<int, DateTime> viewed;

  /// Sync versions of subscriptions, including deleted ones.
  final Map<String, RssSyncStamp> stamps;
  final Map<int, RssSyncStamp> selectionStamps;

  /// Keep rows that this version cannot read. Ordinary saves must not turn a
  /// decoding error into a deletion; a later version can recover the raw row.
  final List<Object?> unreadableSubscriptions;
  final List<Object?> unreadableReleases;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'subscriptions': [
      ...subscriptions.map((value) => value.toJson()),
      ...unreadableSubscriptions,
    ],
    'releases': [
      ...releases.map((value) => value.toJson()),
      ...unreadableReleases,
    ],
    'selected': selected.map((key, value) => MapEntry('$key', value)),
    'viewed': viewed.map(
      (key, value) => MapEntry('$key', value.toUtc().toIso8601String()),
    ),
    'stamps': stamps.map((key, value) => MapEntry(key, _stampJson(value))),
    'selectionStamps': selectionStamps.map(
      (key, value) => MapEntry('$key', _stampJson(value)),
    ),
  };

  static Map<String, Object?> _stampJson(RssSyncStamp stamp) => {
    'at': stamp.at,
    'device': stamp.device,
    'deleted': stamp.deleted,
  };

  static RssSyncStamp? _stamp(Object? value) {
    if (value is! Map || value['at'] is! int) return null;
    final device = value['device'];
    return (
      at: value['at'] as int,
      device: device is String && device.isNotEmpty ? device : null,
      deleted: value['deleted'] == true,
    );
  }

  factory RssStoredState.fromJson(Map value) {
    if ((value['version'] != null && value['version'] != 1) ||
        (value.containsKey('subscriptions') &&
            value['subscriptions'] is! List) ||
        (value.containsKey('releases') && value['releases'] is! List)) {
      throw const RssException('订阅读取失败');
    }
    final subscriptions = <RssSubscription>[];
    final releases = <RssRelease>[];
    final unreadableSubscriptions = <Object?>[];
    final unreadableReleases = <Object?>[];
    for (final row
        in value['subscriptions'] is List
            ? value['subscriptions'] as List
            : const []) {
      try {
        if (row is Map) {
          subscriptions.add(
            RssSubscription.fromJson(Map<String, dynamic>.from(row)),
          );
        } else {
          unreadableSubscriptions.add(row);
        }
      } catch (_) {
        unreadableSubscriptions.add(row);
      }
    }
    for (final row
        in value['releases'] is List ? value['releases'] as List : const []) {
      try {
        if (row is Map) {
          releases.add(RssRelease.fromJson(Map<String, dynamic>.from(row)));
        } else {
          unreadableReleases.add(row);
        }
      } catch (_) {
        unreadableReleases.add(row);
      }
    }
    final selected = <int, String>{};
    if (value['selected'] is Map) {
      for (final entry in (value['selected'] as Map).entries) {
        final id = int.tryParse(entry.key.toString());
        if (id != null && id > 0 && entry.value is String) {
          selected[id] = entry.value as String;
        }
      }
    }
    final viewed = <int, DateTime>{};
    if (value['viewed'] is Map) {
      for (final entry in (value['viewed'] as Map).entries) {
        final id = int.tryParse(entry.key.toString());
        final time = entry.value is String
            ? DateTime.tryParse(entry.value as String)
            : null;
        if (id != null && id > 0 && time != null) viewed[id] = time;
      }
    }
    final stamps = <String, RssSyncStamp>{};
    if (value['stamps'] is Map) {
      for (final entry in (value['stamps'] as Map).entries) {
        final stamp = _stamp(entry.value);
        if (entry.key is String && stamp != null) {
          stamps[entry.key as String] = stamp;
        }
      }
    }
    final selectionStamps = <int, RssSyncStamp>{};
    if (value['selectionStamps'] is Map) {
      for (final entry in (value['selectionStamps'] as Map).entries) {
        final id = int.tryParse(entry.key.toString());
        final stamp = _stamp(entry.value);
        if (id != null && id > 0 && stamp != null) {
          selectionStamps[id] = stamp;
        }
      }
    }
    return RssStoredState(
      subscriptions: subscriptions,
      releases: releases,
      selected: selected,
      viewed: viewed,
      stamps: stamps,
      selectionStamps: selectionStamps,
      unreadableSubscriptions: unreadableSubscriptions,
      unreadableReleases: unreadableReleases,
    );
  }
}

abstract class RssSubscriptionRepository {
  Future<RssStoredState> load();
  Future<void> save(RssStoredState state);
}

/// A separate box stores plain JSON-compatible maps; existing adapters/schema
/// are unchanged. State writes are serialized and published as one Hive value.
class HiveRssSubscriptionRepository implements RssSubscriptionRepository {
  HiveRssSubscriptionRepository({Box<dynamic>? box}) : _injected = box;
  final Box<dynamic>? _injected;
  Future<Box<dynamic>>? _opening;
  Future<void> _writes = Future.value();
  Future<Box<dynamic>> get _box async =>
      _injected ?? await (_opening ??= _openBox());
  Future<Box<dynamic>> _openBox() async {
    try {
      return await Hive.openBox<dynamic>(
        'rss_subscriptions',
        crashRecovery: false,
      );
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  @override
  Future<RssStoredState> load() async {
    final value = (await _box).get('state');
    if (value == null) return const RssStoredState();
    if (value is! Map) {
      throw const RssException('订阅读取失败');
    }
    return RssStoredState.fromJson(value);
  }

  @override
  Future<void> save(RssStoredState state) {
    final snapshot = state.toJson();
    final result = _writes.catchError((Object _) {}).then((_) async {
      final box = await _box;
      await box.put('state', snapshot);
      await box.flush();
    });
    _writes = result;
    return result;
  }
}

class MemoryRssSubscriptionRepository implements RssSubscriptionRepository {
  Map<String, dynamic> _value = const {};
  @override
  Future<RssStoredState> load() async => RssStoredState.fromJson(_value);
  @override
  Future<void> save(RssStoredState state) async {
    _value = state.toJson();
  }
}
