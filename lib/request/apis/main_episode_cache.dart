import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';

/// Main episodes per subject, kept for a while so the detail page, the 追番
/// page and the player share one request. Failures are not cached.
class MainEpisodeCache {
  MainEpisodeCache._();

  static const _ttl = Duration(minutes: 30);
  static final _entries = <int, (DateTime, Future<List<EpisodeInfo>>)>{};

  static Future<List<EpisodeInfo>> get(int subjectId) {
    final cached = _entries[subjectId];
    if (cached != null && DateTime.now().difference(cached.$1) < _ttl) {
      return cached.$2;
    }
    final request = BangumiApi.getBangumiMainEpisodesByID(subjectId);
    _entries[subjectId] = (DateTime.now(), request);
    request.then<void>((_) {}, onError: (Object _) {
      if (identical(_entries[subjectId]?.$2, request)) {
        _entries.remove(subjectId);
      }
    });
    return request;
  }
}
