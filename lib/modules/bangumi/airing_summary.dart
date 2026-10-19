import 'dart:math' as math;

import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/modules/bangumi/broadcast_slot.dart';

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
    BroadcastSlot? slot,
    bool requireBroadcastTime = false,
  }) {
    final day = DateTime(today.year, today.month, today.day);
    final episodes = [...source]
      ..sort((a, b) => a.episode.compareTo(b.episode));
    final total = math.max(plannedTotal, episodes.length);
    // Bangumi episode dates describe Japanese broadcasts, regardless of the
    // device's timezone. bangumi-data provides the actual UTC start time.
    final dated = episodes.where((e) => e.airDay != null).toList();
    final japanStart = slot?.start.toUtc().add(const Duration(hours: 9));
    var dayShift = 0;
    if (japanStart != null && dated.isNotEmpty) {
      final first = dated.first.airDay!;
      final difference = DateTime.utc(
        japanStart.year,
        japanStart.month,
        japanStart.day,
      ).difference(DateTime.utc(first.year, first.month, first.day)).inDays;
      // Late-night broadcasts can have a nominal date one day earlier.
      if (difference.abs() <= 1) dayShift = difference;
    }
    bool hasAired(EpisodeInfo episode) {
      final airDay = episode.airDay;
      if (airDay == null) return false;
      if (slot == null && !requireBroadcastTime) return !airDay.isAfter(day);
      final cutoff = japanStart == null
          // A date alone cannot establish that a show airing later today is
          // already available. Wait until that Japanese calendar day ends.
          ? DateTime.utc(
              airDay.year,
              airDay.month,
              airDay.day + 1,
            ).subtract(const Duration(hours: 9))
          : DateTime.utc(
              airDay.year,
              airDay.month,
              airDay.day + dayShift,
              japanStart.hour,
              japanStart.minute,
              japanStart.second,
            ).subtract(const Duration(hours: 9));
      return !today.toUtc().isBefore(cutoff);
    }

    final aired = episodes.where(hasAired).toList();
    EpisodeInfo? next;
    for (final episode in episodes) {
      if (episode.airDay != null && !hasAired(episode)) {
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
