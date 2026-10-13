import 'dart:math' as math;

import 'package:kazumi/modules/bangumi/episode_item.dart';

enum AiringState { upcoming, airing, finished, unknown }

/// Where a subject's broadcast stands, from its main episodes' air dates.
class AiringSummary {
  AiringSummary._({
    required this.episodes,
    required this.total,
    required this.state,
    required this.airedCount,
    required this.latest,
    required this.next,
  });

  /// [plannedTotal] is Bangumi's planned episode count, when known; episodes
  /// that are listed but not yet dated still count towards the total.
  factory AiringSummary.of(
    List<EpisodeInfo> source, {
    int plannedTotal = 0,
    required DateTime today,
  }) {
    final day = DateTime(today.year, today.month, today.day);
    final episodes = [...source]
      ..sort((a, b) => a.episode.compareTo(b.episode));
    final total = math.max(plannedTotal, episodes.length);
    final aired = episodes
        .where((e) => e.airDay != null && !e.airDay!.isAfter(day))
        .toList();
    EpisodeInfo? next;
    for (final episode in episodes) {
      if (episode.airDay != null && episode.airDay!.isAfter(day)) {
        next = episode;
        break;
      }
    }
    final hasDates = episodes.any((e) => e.airDay != null);
    final state = !hasDates
        ? AiringState.unknown
        : aired.isEmpty
            ? AiringState.upcoming
            : next == null && aired.length >= total
                ? AiringState.finished
                : AiringState.airing;
    return AiringSummary._(
      episodes: episodes,
      total: total,
      state: state,
      airedCount: aired.length,
      latest: aired.isEmpty ? null : aired.last,
      next: next,
    );
  }

  /// Main episodes in broadcast order.
  final List<EpisodeInfo> episodes;
  final int total;
  final AiringState state;
  final int airedCount;

  /// The newest episode that has aired.
  final EpisodeInfo? latest;

  /// The first episode still to air.
  final EpisodeInfo? next;

  bool get finished => state == AiringState.finished;
}
