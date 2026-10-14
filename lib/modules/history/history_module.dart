import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/utils/episode_url.dart';

part 'history_module.g.dart';

class HistoryEntryKind {
  static const String online = 'online';
  static const String offline = 'offline';

  static String normalize(String value) {
    return value == offline ? offline : online;
  }

  HistoryEntryKind._();
}

class PlaybackHistoryIdentity {
  const PlaybackHistoryIdentity({
    required this.bangumiItem,
    required this.pluginName,
    required this.episodeNumber,
    required this.episodeTitle,
    required this.road,
    required this.entryKind,
    this.onlineBangumiSrc = '',
    this.episodePageUrl = '',
    this.legacyEpisodePageUrls = const [],
  });

  final BangumiItem bangumiItem;
  final String pluginName;
  final int episodeNumber;
  final String episodeTitle;
  final int road;
  final String entryKind;
  final String onlineBangumiSrc;
  final String episodePageUrl;
  final List<String> legacyEpisodePageUrls;

  bool get canRecord => pluginName.isNotEmpty && episodeNumber > 0;

  factory PlaybackHistoryIdentity.online({
    required BangumiItem bangumiItem,
    required String pluginName,
    required int episodeNumber,
    required String episodeTitle,
    required int road,
    required String onlineBangumiSrc,
    required String episodePageUrl,
    List<String> legacyEpisodePageUrls = const [],
  }) {
    return PlaybackHistoryIdentity(
      bangumiItem: bangumiItem,
      pluginName: pluginName,
      episodeNumber: episodeNumber,
      episodeTitle: episodeTitle,
      road: road,
      entryKind: HistoryEntryKind.online,
      onlineBangumiSrc: onlineBangumiSrc,
      episodePageUrl: episodePageUrl,
      legacyEpisodePageUrls: legacyEpisodePageUrls,
    );
  }

  factory PlaybackHistoryIdentity.offline({
    required BangumiItem bangumiItem,
    required String pluginName,
    required int episodeNumber,
    required String episodeTitle,
    required int road,
    required String episodePageUrl,
  }) {
    return PlaybackHistoryIdentity(
      bangumiItem: bangumiItem,
      pluginName: pluginName,
      episodeNumber: episodeNumber,
      episodeTitle: episodeTitle,
      road: road,
      entryKind: HistoryEntryKind.offline,
      episodePageUrl: episodePageUrl,
    );
  }
}

@HiveType(typeId: 1)
class History {
  @HiveField(0)
  Map<int, Progress> progresses = {};

  @HiveField(1)
  int lastWatchEpisode;

  @HiveField(2)
  String adapterName;

  @HiveField(3)
  BangumiItem bangumiItem;

  @HiveField(4)
  DateTime lastWatchTime;

  @HiveField(5)
  String lastSrc;

  @HiveField(6, defaultValue: '')
  String lastWatchEpisodeName;

  @HiveField(7, defaultValue: HistoryEntryKind.online)
  String entryKind;

  @HiveField(8, defaultValue: '')
  String episodePageUrl;

  String get key => scopedKey(adapterName, bangumiItem, entryKind);

  /// 第 N 话 of the latest playback; [lastWatchEpisode] is a list position.
  int get watchedEpisodeNumber =>
      episodeNumberFromPageUrl(episodePageUrl) ??
      (episodePageUrl.startsWith('monogatari://episode/')
          ? 0
          : lastWatchEpisode);

  History(
    this.bangumiItem,
    this.lastWatchEpisode,
    this.adapterName,
    this.lastWatchTime,
    this.lastSrc,
    this.lastWatchEpisodeName, {
    this.entryKind = HistoryEntryKind.online,
    this.episodePageUrl = '',
  });

  static String legacyKey(String n, BangumiItem s) => n + s.id.toString();

  static String scopedKey(String n, BangumiItem s, String entryKind) {
    return '${legacyKey(n, s)}::${HistoryEntryKind.normalize(entryKind)}';
  }

  static String getKey(
    String n,
    BangumiItem s, {
    String entryKind = HistoryEntryKind.online,
  }) {
    return scopedKey(n, s, entryKind);
  }

  @override
  String toString() {
    return 'Adapter: $adapterName, anime: ${bangumiItem.name}';
  }
}

@HiveType(typeId: 2)
class Progress {
  @HiveField(0)
  int episode;

  @HiveField(1)
  int road;

  @HiveField(2)
  int _progressInMilli;

  @HiveField(3, defaultValue: 0)
  int updatedAtMs;

  @HiveField(4, defaultValue: '')
  String episodePageUrl;

  Duration get progress => Duration(milliseconds: _progressInMilli);

  set progress(Duration d) => _progressInMilli = d.inMilliseconds;

  Progress(
    this.episode,
    this.road,
    this._progressInMilli, {
    this.updatedAtMs = 0,
    this.episodePageUrl = '',
  });

  /// 第 N 话 of this record; [episode] is a list position.
  int get episodeNumber =>
      episodeNumberFromPageUrl(episodePageUrl) ??
      (episodePageUrl.startsWith('monogatari://episode/') ? 0 : episode);

  int effectiveUpdatedAtMs(DateTime fallback) {
    return updatedAtMs > 0 ? updatedAtMs : fallback.millisecondsSinceEpoch;
  }

  @override
  String toString() {
    return 'Episode ${episode.toString()}, progress $progress';
  }
}
