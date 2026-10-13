import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_type.dart';

enum CollectSort {
  recentlyWatched('最近观看'),
  recentlyChanged('最近变更'),
  title('番剧名称'),
  rating('评分最高'),
  airDate('开播时间');

  const CollectSort(this.label);
  final String label;

  static CollectSort fromName(String name) => values.firstWhere(
        (sort) => sort.name == name,
        orElse: () => recentlyWatched,
      );
}

class CollectLibraryQuery {
  CollectLibraryQuery(Iterable<CollectedBangumi> items, String query)
      : _matches = _match(items, query);

  final List<CollectedBangumi> _matches;

  static List<CollectedBangumi> _match(
      Iterable<CollectedBangumi> items, String query) {
    final terms = query.trim().toLowerCase().split(RegExp(r'\s+'));
    return items.where((entry) {
      if (!CollectType.fromValue(entry.type).isCollected) return false;
      final item = entry.bangumiItem;
      final names =
          [item.nameCn, item.name, ...item.alias].join('\n').toLowerCase();
      return terms.every(names.contains);
    }).toList();
  }

  int count(CollectType? type) => type == null
      ? _matches.length
      : _matches.where((entry) => entry.type == type.value).length;

  /// [lastWatched] maps subject ids to their latest playback; under
  /// [CollectSort.recentlyWatched], shows never played follow by change time.
  List<CollectedBangumi> results(
    CollectType? type,
    CollectSort sort, {
    Map<int, DateTime> lastWatched = const {},
  }) {
    final result = _matches
        .where((entry) => type == null || entry.type == type.value)
        .toList();
    DateTime watchedAt(CollectedBangumi entry) =>
        lastWatched[entry.bangumiItem.id] ?? DateTime(0);
    result.sort((a, b) {
      final comparison = switch (sort) {
        CollectSort.recentlyWatched => watchedAt(b).compareTo(watchedAt(a)),
        CollectSort.recentlyChanged => b.time.compareTo(a.time),
        CollectSort.title => titleOf(a).toLowerCase().compareTo(
              titleOf(b).toLowerCase(),
            ),
        CollectSort.rating =>
          b.bangumiItem.ratingScore.compareTo(a.bangumiItem.ratingScore),
        CollectSort.airDate => _airDate(b).compareTo(_airDate(a)),
      };
      if (comparison != 0) return comparison;
      final byTime = b.time.compareTo(a.time);
      return byTime != 0
          ? byTime
          : a.bangumiItem.id.compareTo(b.bangumiItem.id);
    });
    return result;
  }

  static String titleOf(CollectedBangumi entry) {
    final item = entry.bangumiItem;
    return item.nameCn.trim().isNotEmpty ? item.nameCn : item.name;
  }

  static DateTime _airDate(CollectedBangumi entry) =>
      DateTime.tryParse(entry.bangumiItem.airDate) ?? DateTime(0);
}
