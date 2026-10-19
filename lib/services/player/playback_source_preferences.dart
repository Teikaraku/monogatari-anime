import 'package:kazumi/services/storage/storage.dart';

/// User-selected source per subject. Register one shared application instance;
/// source lookup and automatic fallback never write a preference.
class PlaybackSourcePreferences {
  PlaybackSourcePreferences({
    Object? Function()? read,
    Future<void> Function(Map<dynamic, dynamic>)? write,
  }) : _read = read ?? _readStored,
       _write = write ?? _writeStored;

  final Object? Function() _read;
  final Future<void> Function(Map<dynamic, dynamic>) _write;
  final Map<int, ({int revision, String source})> _pending = {};
  int _nextRevision = 0;
  Future<void> _writes = Future.value();

  String? forSubject(int bangumiId) {
    if (bangumiId <= 0) return null;
    return _pending[bangumiId]?.source ?? _decode(_read())[bangumiId];
  }

  /// The selection becomes readable immediately. The returned future confirms
  /// its durable write. Reads stay aligned with restored settings, and queued
  /// writes merge into the current storage instead of reviving deleted choices.
  Future<void> remember(int bangumiId, String source) {
    if (bangumiId <= 0 || (source != 'api' && source != 'rss')) {
      return Future.value();
    }
    final revision = ++_nextRevision;
    _pending[bangumiId] = (revision: revision, source: source);
    final result = _writes.catchError((Object _) {}).then((_) async {
      try {
        final sources = _decode(_read())..[bangumiId] = source;
        await _write(
          Map<dynamic, dynamic>.unmodifiable(
            sources.map((id, value) => MapEntry('$id', value)),
          ),
        );
      } finally {
        if (_pending[bangumiId]?.revision == revision) {
          _pending.remove(bangumiId);
        }
      }
    });
    _writes = result;
    return result;
  }

  static Map<int, String> _decode(Object? value) {
    final sources = <int, String>{};
    if (value is! Map) return sources;
    for (final entry in value.entries) {
      final key = entry.key;
      final id = key is int
          ? key
          : key is String && RegExp(r'^\d+$').hasMatch(key)
          ? int.tryParse(key)
          : null;
      if (id != null &&
          id > 0 &&
          (entry.value == 'api' || entry.value == 'rss')) {
        sources[id] = entry.value as String;
      }
    }
    return sources;
  }

  static Object? _readStored() =>
      GStorage.getSetting(SettingsKeys.subjectPlaybackSources);

  static Future<void> _writeStored(Map<dynamic, dynamic> value) =>
      GStorage.putSetting(SettingsKeys.subjectPlaybackSources, value);
}
