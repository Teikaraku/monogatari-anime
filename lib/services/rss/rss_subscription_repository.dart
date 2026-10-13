import 'package:hive_ce/hive.dart';

import 'rss_models.dart';

class RssStoredState {
  const RssStoredState({
    this.subscriptions = const [],
    this.releases = const [],
    this.selected = const {},
  });
  final List<RssSubscription> subscriptions;
  final List<RssRelease> releases;
  final Map<int, String> selected;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'subscriptions': subscriptions.map((value) => value.toJson()).toList(),
    'releases': releases.map((value) => value.toJson()).toList(),
    'selected': selected.map((key, value) => MapEntry('$key', value)),
  };

  factory RssStoredState.fromJson(Map value) {
    final subscriptions = <RssSubscription>[];
    final releases = <RssRelease>[];
    for (final row
        in value['subscriptions'] is List
            ? value['subscriptions'] as List
            : const []) {
      try {
        if (row is Map) {
          subscriptions.add(
            RssSubscription.fromJson(Map<String, dynamic>.from(row)),
          );
        }
      } catch (_) {}
    }
    for (final row
        in value['releases'] is List ? value['releases'] as List : const []) {
      try {
        if (row is Map) {
          releases.add(RssRelease.fromJson(Map<String, dynamic>.from(row)));
        }
      } catch (_) {}
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
    return RssStoredState(
      subscriptions: subscriptions,
      releases: releases,
      selected: selected,
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
      return await Hive.openBox<dynamic>('rss_subscriptions');
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  @override
  Future<RssStoredState> load() async {
    final value = (await _box).get('state');
    return value is Map
        ? RssStoredState.fromJson(value)
        : const RssStoredState();
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
