import 'dart:async';

import 'package:dio/dio.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';

typedef InfoCatalogWarmup =
    Future<void> Function(BangumiItem subject, CancelToken cancelToken);

/// Owns only the detail route's metadata warmup subscription. Playback has its
/// own cancellation owner even when both subscriptions share a service flight.
class InfoCatalogPrefetch {
  InfoCatalogPrefetch(this._warmup);

  final InfoCatalogWarmup _warmup;
  int _revision = 0;
  int? _subjectId;
  bool _disposed = false;
  CancelToken? _cancellation;

  int beginSubject(int subjectId) {
    _cancellation?.cancel();
    _cancellation = null;
    _subjectId = subjectId;
    return ++_revision;
  }

  bool isCurrent(int revision, int subjectId) =>
      !_disposed && _revision == revision && _subjectId == subjectId;

  void afterDetailsApplied(int revision, BangumiItem subject) {
    if (!isCurrent(revision, subject.id)) return;
    _cancellation?.cancel();
    final cancellation = CancelToken();
    _cancellation = cancellation;
    // Mutable list-card metadata must not change the matching key of a warmup
    // that has already started. Preserve the fully resolved names and aliases.
    final snapshot = BangumiItem(
      id: subject.id,
      type: subject.type,
      name: subject.name,
      nameCn: subject.nameCn,
      summary: subject.summary,
      airDate: subject.airDate,
      airWeekday: subject.airWeekday,
      rank: subject.rank,
      images: Map.of(subject.images),
      tags: List.of(subject.tags),
      alias: List.of(subject.alias),
      ratingScore: subject.ratingScore,
      votes: subject.votes,
      votesCount: List.of(subject.votesCount),
      info: subject.info,
      metaTags: List.of(subject.metaTags),
    );
    unawaited(
      Future<void>.sync(() => _warmup(snapshot, cancellation)).catchError((
        Object _,
      ) {
        // A warmup is optional. Playback can perform the normal lookup later.
      }),
    );
  }

  void dispose() {
    _disposed = true;
    _revision++;
    _cancellation?.cancel();
    _cancellation = null;
  }
}
