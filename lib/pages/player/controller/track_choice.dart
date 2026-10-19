import 'package:kazumi/services/subject/subject_local_store.dart';

/// The parts of an audio or subtitle track used to find it again.
typedef TrackInfo = ({String id, String? title, String? language});

/// mpv lists the pseudo tracks 'auto' and 'no' with the file's own ones.
bool isRealTrack(String id) => id != 'auto' && id != 'no';

/// Finds the track a show used last time among the file's own [tracks]: the
/// same language and title, then the same title, then the same language,
/// then the same position.
int? matchTrackIndex(List<TrackInfo> tracks, TrackChoice choice) {
  if (tracks.isEmpty || choice.off) return null;
  final language = _normal(choice.language);
  final title = _normal(choice.title);
  int? find(bool Function(TrackInfo) test) {
    for (var i = 0; i < tracks.length; i++) {
      if (test(tracks[i])) return i;
    }
    return null;
  }

  if (language != null && title != null) {
    final both = find(
      (t) => _normal(t.language) == language && _normal(t.title) == title,
    );
    if (both != null) return both;
  }
  if (title != null) {
    final byTitle = find((t) => _normal(t.title) == title);
    if (byTitle != null) return byTitle;
  }
  if (language != null) {
    final byLanguage = find((t) => _normal(t.language) == language);
    if (byLanguage != null) return byLanguage;
  }
  final index = choice.index;
  return index != null && index < tracks.length ? index : null;
}

/// What to remember about [tracks][index].
TrackChoice choiceFor(List<TrackInfo> tracks, int index) => TrackChoice(
  language: tracks[index].language,
  title: tracks[index].title,
  index: index,
);

String? _normal(String? value) {
  final text = value?.trim().toLowerCase();
  return text == null || text.isEmpty ? null : text;
}

const _languageNames = {
  'chi': '中文',
  'zho': '中文',
  'zh': '中文',
  'chs': '简体中文',
  'sc': '简体中文',
  'zh-hans': '简体中文',
  'cht': '繁体中文',
  'tc': '繁体中文',
  'zh-hant': '繁体中文',
  'jpn': '日语',
  'ja': '日语',
  'eng': '英语',
  'en': '英语',
  'kor': '韩语',
  'ko': '韩语',
};

/// 简体中文 · 北宇治字幕组, or 字幕 2 when the file names nothing.
String trackLabel(TrackInfo track, int index, String kind) {
  final language =
      _languageNames[_normal(track.language)] ??
      (track.language == null || _normal(track.language) == 'und'
          ? null
          : track.language);
  final title = track.title?.trim();
  final parts = [
    if (title != null && title.isNotEmpty) title,
    if (language != null && language != title) language,
  ];
  return parts.isEmpty ? '$kind ${index + 1}' : parts.join(' · ');
}
