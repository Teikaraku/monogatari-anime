import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/anime_season.dart';

/// What the user did with a card.
enum PreviewDecision {
  skip(CollectType.none),
  planToWatch(CollectType.planToWatch),
  watching(CollectType.watching);

  const PreviewDecision(this.collectType);

  /// The 追番 state the card's show gets; none only marks it seen.
  final CollectType collectType;
}

/// 新番速览 cards: the season's new shows not in 追番 and not decided before,
/// most popular first. Decisions can be undone one at a time.
class SeasonPreviewDeck {
  SeasonPreviewDeck(this.items);

  final List<BangumiItem> items;
  final _decisions = <(BangumiItem, PreviewDecision)>[];
  int _index = 0;

  int get remaining => items.length - _index;
  bool get isDone => _index >= items.length;
  BangumiItem? get current => isDone ? null : items[_index];
  BangumiItem? get next => _index + 1 < items.length ? items[_index + 1] : null;

  /// The shows after the next card, for warming their covers.
  Iterable<BangumiItem> upcoming(int count) =>
      items.skip(_index + 2).take(count);

  bool get canUndo => _decisions.isNotEmpty;

  void decide(PreviewDecision decision) {
    final item = current;
    if (item == null) return;
    _decisions.add((item, decision));
    _index++;
  }

  /// Steps back one card and returns the decision taken on it.
  (BangumiItem, PreviewDecision)? undo() {
    if (_decisions.isEmpty) return null;
    _index--;
    return _decisions.removeLast();
  }

  /// Orders [shows] by how many people rated them, dropping duplicates and
  /// the ids in [exclude].
  static List<BangumiItem> arrange(
    Iterable<BangumiItem> shows, {
    Set<int> exclude = const {},
  }) {
    final seen = <int>{...exclude};
    final result = [
      for (final show in shows)
        if (seen.add(show.id)) show,
    ];
    result.sort((a, b) {
      final votes = b.votes.compareTo(a.votes);
      return votes != 0 ? votes : b.ratingScore.compareTo(a.ratingScore);
    });
    return result;
  }
}

/// Season-scoped memory of decided cards and this launch's show list.
class SeasonPreviewStore {
  SeasonPreviewStore._();
  static final instance = SeasonPreviewStore._();

  static final Map<String, List<BangumiItem>> _loaded = {};

  /// '2026-3' for autumn 2026.
  static String seasonKey(DateTime date) =>
      '${date.year}-${(date.month - 1) ~/ 3}';

  Set<int> seen(String season) {
    final raw = GStorage.getSetting(SettingsKeys.seasonPreviewSeen)[season];
    return {
      if (raw is List)
        for (final id in raw)
          if (id is int) id,
    };
  }

  Future<void> setSeen(String season, int id, bool value) {
    final all = Map<dynamic, dynamic>.from(
      GStorage.getSetting(SettingsKeys.seasonPreviewSeen),
    );
    final ids = seen(season);
    value ? ids.add(id) : ids.remove(id);
    // Only the current season matters; older ones are dropped.
    all
      ..removeWhere((key, _) => key != season)
      ..[season] = ids.toList();
    return GStorage.putSetting(SettingsKeys.seasonPreviewSeen, all);
  }

  /// The season's new TV and web shows, fetched once per launch.
  Future<List<BangumiItem>> load(DateTime date) async {
    final key = seasonKey(date);
    final cached = _loaded[key];
    if (cached != null) return cached;
    final days = await BangumiApi.getSeasonCalendar(
      AnimeSeason(date).toSeasonStartAndEnd(),
    );
    return _loaded[key] = [for (final day in days) ...day];
  }
}
