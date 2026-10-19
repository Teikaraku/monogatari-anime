class EpisodeInfo {
  int id;
  num episode;
  int type;
  String name;
  String nameCn;

  /// Number within the season (`ep`); falls back to [episode] (`sort`).
  num seasonEpisode;
  String airDate;
  String duration;
  String summary;
  int commentCount;

  EpisodeInfo({
    required this.id,
    required this.episode,
    required this.type,
    required this.name,
    required this.nameCn,
    this.seasonEpisode = 0,
    this.airDate = '',
    this.duration = '',
    this.summary = '',
    this.commentCount = 0,
  });

  factory EpisodeInfo.fromJson(Map<String, dynamic> json) {
    return EpisodeInfo(
        id: json['id'] ?? 0,
        episode: json['sort'] ?? 0,
        type: json['type'] ?? 0,
        name: json['name'] ?? '',
        nameCn: json['name_cn'] ?? json['nameCN'] ?? '',
        seasonEpisode: json['ep'] ?? 0,
        airDate: (json['airdate'] ?? '').toString().trim(),
        duration: (json['duration'] ?? '').toString().trim(),
        summary: (json['desc'] ?? '').toString().trim(),
        commentCount: json['comment'] ?? 0);
  }

  factory EpisodeInfo.fromTemplate() {
    return EpisodeInfo(id: 0, episode: 0, type: 0, name: '', nameCn: '');
  }

  void reset() {
    id = 0;
    episode = 0;
    type = 0;
    name = '';
    nameCn = '';
    seasonEpisode = 0;
    airDate = '';
    duration = '';
    summary = '';
    commentCount = 0;
  }

  /// The number shown to users: the in-season number when Bangumi has one.
  num get displayNumber => seasonEpisode > 0 ? seasonEpisode : episode;

  /// The air date as a local calendar day, or null when unknown.
  DateTime? get airDay {
    final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(airDate);
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    if (year < 1900 || month < 1 || month > 12 || day < 1 || day > 31) {
      return null;
    }
    return DateTime(year, month, day);
  }

  String readType() {
    switch (type) {
      case 0:
        return 'ep';
      case 1:
        return 'sp';
      case 2:
        return 'op';
      case 3:
        return 'ed';
      default:
        return '';
    }
  }
}
