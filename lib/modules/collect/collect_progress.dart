import 'package:kazumi/modules/bangumi/airing_summary.dart';
import 'package:kazumi/modules/bangumi/broadcast_slot.dart';
import 'package:kazumi/modules/history/history_module.dart';

const _weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];

/// What the 追番 page knows about a collected show beyond the collection:
/// the latest watch record, the airing progress and the broadcast slot.
/// Each part may be missing.
class CollectProgress {
  const CollectProgress({this.history, this.airing, this.slot});

  final History? history;
  final AiringSummary? airing;
  final BroadcastSlot? slot;

  int? get watchedEpisode => history?.watchedEpisodeNumber;

  num? get latestAired => airing?.latest?.displayNumber;

  /// An episode has aired after the one last watched.
  bool get hasUpdate {
    final watched = watchedEpisode;
    final latest = latestAired;
    return watched != null && latest != null && latest > watched;
  }

  /// "看到第 1 话 · 更新至第 2 话"; empty when nothing is known.
  String get progressLabel {
    final airing = this.airing;
    return [
      if (watchedEpisode != null) '看到第 $watchedEpisode 话',
      if (airing != null && airing.finished)
        '全 ${airing.total} 话'
      else if (latestAired != null)
        '更新至第 $latestAired 话',
    ].join(' · ');
  }

  /// "每周四 20:30 更新" while the show is still airing.
  String? get scheduleLabel {
    final slot = this.slot;
    if (slot == null || airing == null || airing!.finished) return null;
    return '每周${_weekdayNames[slot.localWeekday - 1]} '
        '${slot.localTimeLabel} 更新';
  }
}
