import 'package:flutter/foundation.dart';
import 'package:kazumi/services/storage/storage.dart';

typedef SubjectStoreRead = Object? Function();
typedef SubjectStoreWrite = Future<void> Function(Map<dynamic, dynamic> value);

/// A map by Bangumi id kept under one settings key. It is decoded once, kept in
/// memory and rewritten whole on change; these maps stay small.
abstract class SubjectMapStore<V> extends ChangeNotifier {
  SubjectMapStore(
    SettingKey<Map<dynamic, dynamic>> key, {
    SubjectStoreRead? read,
    SubjectStoreWrite? write,
  }) : _read = read ?? (() => GStorage.getSetting(key)),
       _write = write ?? ((value) => GStorage.putSetting(key, value));

  final SubjectStoreRead _read;
  final SubjectStoreWrite _write;
  Map<int, V>? _values;
  Future<void> _writes = Future.value();

  V? decodeValue(Object? raw);
  Object encodeValue(V value);

  Map<int, V> get _all => _values ??= _decode(_read());

  Map<int, V> _decode(Object? raw) {
    final result = <int, V>{};
    if (raw is! Map) return result;
    for (final entry in raw.entries) {
      final id = int.tryParse('${entry.key}');
      if (id == null || id <= 0) continue;
      final value = decodeValue(entry.value);
      if (value != null) result[id] = value;
    }
    return result;
  }

  V? valueFor(int id) => _all[id];

  /// Null removes the entry. Writes are queued so the latest always lands.
  Future<void> put(int id, V? value) {
    if (id <= 0) return Future.value();
    if (value == null) {
      if (_all.remove(id) == null) return Future.value();
    } else {
      _all[id] = value;
    }
    notifyListeners();
    final snapshot = {
      for (final entry in _all.entries)
        '${entry.key}': encodeValue(entry.value),
    };
    return _writes = _writes
        .catchError((Object _) {})
        .then((_) => _write(Map<dynamic, dynamic>.unmodifiable(snapshot)));
  }
}

/// One line the user wrote about a show, such as 等完结再看.
class SubjectNotes extends SubjectMapStore<String> {
  SubjectNotes({super.read, super.write}) : super(SettingsKeys.subjectNotes);

  static const maxLength = 60;

  String? noteFor(int id) => valueFor(id);

  Future<void> setNote(int id, String text) {
    final trimmed = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final note = trimmed.length > maxLength
        ? trimmed.substring(0, maxLength)
        : trimmed;
    return put(id, note.isEmpty ? null : note);
  }

  @override
  String? decodeValue(Object? raw) =>
      raw is String && raw.trim().isNotEmpty ? raw : null;

  @override
  Object encodeValue(String value) => value;
}

/// Episodes the user marked by hand: true for 看过, false for 没看过. A mark
/// overrides what the watch records say about that episode.
class EpisodeMarks extends SubjectMapStore<Map<int, bool>> {
  EpisodeMarks({super.read, super.write})
    : super(SettingsKeys.episodeWatchMarks);

  Map<int, bool> marksFor(int id) => valueFor(id) ?? const {};

  Future<void> mark(int id, Iterable<int> episodes, {required bool watched}) {
    final next = {...marksFor(id)};
    for (final episode in episodes) {
      if (episode > 0) next[episode] = watched;
    }
    return put(id, next.isEmpty ? null : next);
  }

  @override
  Map<int, bool>? decodeValue(Object? raw) {
    if (raw is! Map) return null;
    final result = <int, bool>{
      for (final entry in raw.entries)
        if (int.tryParse('${entry.key}') case final episode?
            when episode > 0 && entry.value is bool)
          episode: entry.value as bool,
    };
    return result.isEmpty ? null : result;
  }

  @override
  Object encodeValue(Map<int, bool> value) => {
    for (final entry in value.entries) '${entry.key}': entry.value,
  };
}

/// A track picked by the user, matched again by language and title, then by
/// its position, on the next episode.
@immutable
class TrackChoice {
  const TrackChoice({this.language, this.title, this.index, this.off = false});

  final String? language;
  final String? title;

  /// Position among the file's own tracks of this kind.
  final int? index;

  /// Subtitles turned off.
  final bool off;

  static TrackChoice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final index = raw['index'];
    return TrackChoice(
      language: raw['language'] is String ? raw['language'] as String : null,
      title: raw['title'] is String ? raw['title'] as String : null,
      index: index is int && index >= 0 ? index : null,
      off: raw['off'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    if (language != null) 'language': language,
    if (title != null) 'title': title,
    if (index != null) 'index': index,
    if (off) 'off': true,
  };
}

/// The player settings a show keeps: speed, danmaku and its tracks.
@immutable
class PlayerChoices {
  const PlayerChoices({this.speed, this.danmaku, this.audio, this.subtitle});

  final double? speed;
  final bool? danmaku;
  final TrackChoice? audio;
  final TrackChoice? subtitle;

  bool get isEmpty =>
      speed == null && danmaku == null && audio == null && subtitle == null;

  PlayerChoices copyWith({
    double? speed,
    bool? danmaku,
    TrackChoice? audio,
    TrackChoice? subtitle,
  }) => PlayerChoices(
    speed: speed ?? this.speed,
    danmaku: danmaku ?? this.danmaku,
    audio: audio ?? this.audio,
    subtitle: subtitle ?? this.subtitle,
  );
}

class SubjectPlayerChoices extends SubjectMapStore<PlayerChoices> {
  SubjectPlayerChoices({super.read, super.write})
    : super(SettingsKeys.subjectPlayerChoices);

  PlayerChoices choicesFor(int id) => valueFor(id) ?? const PlayerChoices();

  Future<void> update(
    int id, {
    double? speed,
    bool? danmaku,
    TrackChoice? audio,
    TrackChoice? subtitle,
  }) {
    final next = choicesFor(id).copyWith(
      speed: speed,
      danmaku: danmaku,
      audio: audio,
      subtitle: subtitle,
    );
    return put(id, next.isEmpty ? null : next);
  }

  @override
  PlayerChoices? decodeValue(Object? raw) {
    if (raw is! Map) return null;
    final speed = raw['speed'];
    final choices = PlayerChoices(
      speed: speed is num && speed > 0 && speed <= 8 ? speed.toDouble() : null,
      danmaku: raw['danmaku'] is bool ? raw['danmaku'] as bool : null,
      audio: TrackChoice.fromJson(raw['audio']),
      subtitle: TrackChoice.fromJson(raw['subtitle']),
    );
    return choices.isEmpty ? null : choices;
  }

  @override
  Object encodeValue(PlayerChoices value) => {
    if (value.speed != null) 'speed': value.speed,
    if (value.danmaku != null) 'danmaku': value.danmaku,
    if (value.audio != null) 'audio': value.audio!.toJson(),
    if (value.subtitle != null) 'subtitle': value.subtitle!.toJson(),
  };
}
