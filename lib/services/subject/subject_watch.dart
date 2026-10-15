import 'package:kazumi/modules/history/history_module.dart';

/// What the app knows about how far a show has been watched: its watch
/// records, adjusted by the episodes the user marked by hand.
class SubjectWatch {
  const SubjectWatch({
    this.latest,
    required this.watched,
    this.marks = const {},
  });

  /// Builds the state of [subjectId] from every playback library's records.
  factory SubjectWatch.of(
    Iterable<History> histories,
    int subjectId, {
    Map<int, bool> marks = const {},
  }) {
    History? latest;
    final recorded = <int>{};
    for (final record in histories) {
      if (record.bangumiItem.id != subjectId) continue;
      if (latest == null ||
          record.lastWatchTime.isAfter(latest.lastWatchTime)) {
        latest = record;
      }
      for (final progress in record.progresses.values) {
        final number = progress.episodeNumber;
        if (number > 0) recorded.add(number);
      }
    }
    return SubjectWatch(
      latest: latest,
      watched: watchedWith(recorded, marks),
      marks: marks,
    );
  }

  /// The most recent record across libraries; resuming continues it.
  final History? latest;

  /// Episode numbers (第 N 话) counted as watched.
  final Set<int> watched;
  final Map<int, bool> marks;

  static Set<int> watchedWith(Set<int> recorded, Map<int, bool> marks) {
    if (marks.isEmpty) return recorded;
    return {
      for (final number in recorded)
        if (marks[number] != false) number,
      for (final entry in marks.entries)
        if (entry.value) entry.key,
    };
  }

  /// 看到第 N 话: the last episode played, or with manual marks the furthest
  /// episode counted as watched.
  int? get lastWatched {
    if (marks.isEmpty) {
      final played = latest?.watchedEpisodeNumber;
      return played != null && played > 0 ? played : null;
    }
    if (watched.isEmpty) return null;
    return watched.reduce((a, b) => a > b ? a : b);
  }
}
