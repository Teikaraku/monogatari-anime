import 'package:kazumi/modules/bangumi/bangumi_item.dart';

class MikanSubtitleGroup {
  const MikanSubtitleGroup({
    required this.id,
    required this.name,
    required this.feedUri,
  });
  final int id;
  final String name;
  final Uri feedUri;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'feedUri': feedUri.toString(),
  };
  factory MikanSubtitleGroup.fromJson(Map<String, dynamic> value) =>
      MikanSubtitleGroup(
        id: value['id'] as int,
        name: value['name'] as String,
        feedUri: Uri.parse(value['feedUri'] as String),
      );
}

class MikanShow {
  const MikanShow({
    required this.id,
    required this.title,
    required this.detailUri,
    this.bangumiId,
    this.groups = const [],
  });
  final int id;
  final String title;
  final Uri detailUri;
  final int? bangumiId;
  final List<MikanSubtitleGroup> groups;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'detailUri': detailUri.toString(),
    'bangumiId': bangumiId,
    'groups': groups.map((group) => group.toJson()).toList(),
  };
  factory MikanShow.fromJson(Map<String, dynamic> value) => MikanShow(
    id: value['id'] as int,
    title: value['title'] as String,
    detailUri: Uri.parse(value['detailUri'] as String),
    bangumiId: value['bangumiId'] as int?,
    groups: (value['groups'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (group) =>
              MikanSubtitleGroup.fromJson(Map<String, dynamic>.from(group)),
        )
        .toList(),
  );
}

class RssSubscription {
  const RssSubscription({
    required this.id,
    required this.subject,
    required this.show,
    required this.group,
    required this.createdAt,
    this.enabled = true,
    this.lastRefreshedAt,
    this.lastError,
  });
  final String id;
  final BangumiItem subject;
  final MikanShow show;
  final MikanSubtitleGroup group;
  final DateTime createdAt;
  final bool enabled;
  final DateTime? lastRefreshedAt;
  final String? lastError;
  int get bangumiId => subject.id;
  int get mikanId => show.id;
  Uri get feedUri => group.feedUri;
  int get subtitleGroupId => group.id;
  String get subtitleGroupName => group.name;
  String get title => subject.nameCn.isNotEmpty ? subject.nameCn : subject.name;
  bool get isVerified => show.bangumiId == subject.id;

  RssSubscription copyWith({
    bool? enabled,
    DateTime? lastRefreshedAt,
    String? lastError,
    bool clearError = false,
  }) => RssSubscription(
    id: id,
    subject: subject,
    show: show,
    group: group,
    createdAt: createdAt,
    enabled: enabled ?? this.enabled,
    lastRefreshedAt: lastRefreshedAt ?? this.lastRefreshedAt,
    lastError: clearError ? null : lastError ?? this.lastError,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'subject': rssSubjectToJson(subject),
    'show': show.toJson(),
    'group': group.toJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'enabled': enabled,
    'lastRefreshedAt': lastRefreshedAt?.toUtc().toIso8601String(),
    'lastError': lastError,
  };
  factory RssSubscription.fromJson(Map<String, dynamic> value) =>
      RssSubscription(
        id: value['id'] as String,
        subject: BangumiItem.fromJson(
          Map<String, dynamic>.from(value['subject'] as Map),
        ),
        show: MikanShow.fromJson(
          Map<String, dynamic>.from(value['show'] as Map),
        ),
        group: MikanSubtitleGroup.fromJson(
          Map<String, dynamic>.from(value['group'] as Map),
        ),
        createdAt: DateTime.parse(value['createdAt'] as String),
        enabled: value['enabled'] as bool? ?? true,
        lastRefreshedAt: DateTime.tryParse(
          value['lastRefreshedAt'] as String? ?? '',
        ),
        lastError: value['lastError'] as String?,
      );
}

class RssRelease {
  const RssRelease({
    required this.key,
    required this.title,
    required this.detailUri,
    this.torrentUri,
    this.magnetUri,
    this.episodeNumber,
    this.episodeNumbers = const [],
    this.isBatch = false,
    this.isSpecial = false,
    this.specialKey,
    this.quality = '',
    this.group = '',
    this.publishedAt,
    this.sizeBytes,
    this.subscriptionId = '',
    this.bangumiId,
    this.mikanId,
    this.subtitleGroupId,
  });
  final String key;
  final String title;
  final Uri detailUri;
  final Uri? torrentUri;
  final Uri? magnetUri;
  final double? episodeNumber;
  final List<double> episodeNumbers;
  final bool isBatch;
  final bool isSpecial;
  final String? specialKey;
  final String quality;
  final String group;
  final DateTime? publishedAt;
  final int? sizeBytes;
  final String subscriptionId;
  final int? bangumiId;
  final int? mikanId;
  final int? subtitleGroupId;
  Uri get sourceUri => torrentUri ?? magnetUri!;
  List<double> get batchEpisodeNumbers => episodeNumbers;
  bool matchesEpisode(double number) =>
      !isSpecial &&
      (episodeNumber == number || episodeNumbers.contains(number));

  RssRelease bind(RssSubscription subscription) => RssRelease(
    key: '${subscription.id}/$key',
    title: title,
    detailUri: detailUri,
    torrentUri: torrentUri,
    magnetUri: magnetUri,
    episodeNumber: episodeNumber,
    episodeNumbers: episodeNumbers,
    isBatch: isBatch,
    isSpecial: isSpecial,
    specialKey: specialKey,
    quality: quality,
    group: group,
    publishedAt: publishedAt,
    sizeBytes: sizeBytes,
    subscriptionId: subscription.id,
    bangumiId: subscription.bangumiId,
    mikanId: subscription.mikanId,
    subtitleGroupId: subscription.subtitleGroupId,
  );
  Map<String, dynamic> toJson() => {
    'key': key,
    'title': title,
    'detailUri': detailUri.toString(),
    'torrentUri': torrentUri?.toString(),
    'magnetUri': magnetUri?.toString(),
    'episodeNumber': episodeNumber,
    'episodeNumbers': episodeNumbers,
    'isBatch': isBatch,
    'isSpecial': isSpecial,
    'specialKey': specialKey,
    'quality': quality,
    'group': group,
    'publishedAt': publishedAt?.toUtc().toIso8601String(),
    'sizeBytes': sizeBytes,
    'subscriptionId': subscriptionId,
    'bangumiId': bangumiId,
    'mikanId': mikanId,
    'subtitleGroupId': subtitleGroupId,
  };
  factory RssRelease.fromJson(Map<String, dynamic> value) => RssRelease(
    key: value['key'] as String,
    title: value['title'] as String,
    detailUri: Uri.parse(value['detailUri'] as String),
    torrentUri: value['torrentUri'] is String
        ? Uri.parse(value['torrentUri'] as String)
        : null,
    magnetUri: value['magnetUri'] is String
        ? Uri.parse(value['magnetUri'] as String)
        : null,
    episodeNumber: (value['episodeNumber'] as num?)?.toDouble(),
    episodeNumbers: (value['episodeNumbers'] as List? ?? const [])
        .whereType<num>()
        .map((number) => number.toDouble())
        .toList(),
    isBatch: value['isBatch'] as bool? ?? false,
    isSpecial: value['isSpecial'] as bool? ?? false,
    specialKey: value['specialKey'] as String?,
    quality: value['quality'] as String? ?? '',
    group: value['group'] as String? ?? '',
    publishedAt: DateTime.tryParse(value['publishedAt'] as String? ?? ''),
    sizeBytes: value['sizeBytes'] as int?,
    subscriptionId: value['subscriptionId'] as String? ?? '',
    bangumiId: value['bangumiId'] as int?,
    mikanId: value['mikanId'] as int?,
    subtitleGroupId: value['subtitleGroupId'] as int?,
  );
}

class RssFeedPreview {
  const RssFeedPreview({
    required this.uri,
    required this.title,
    required this.releases,
    this.mikanId,
    this.subtitleGroupId,
    this.bangumiId,
  });
  final Uri uri;
  final String title;
  final List<RssRelease> releases;
  final int? mikanId;
  final int? subtitleGroupId;
  final int? bangumiId;
}

class RssTitleMetadata {
  const RssTitleMetadata({
    this.episodeNumber,
    this.episodeNumbers = const [],
    this.isBatch = false,
    this.isSpecial = false,
    this.specialKey,
    this.quality = '',
    this.group = '',
  });
  final double? episodeNumber;
  final List<double> episodeNumbers;
  final bool isBatch;
  final bool isSpecial;
  final String? specialKey;
  final String quality;
  final String group;
}

Map<String, dynamic> rssSubjectToJson(BangumiItem subject) => {
  'id': subject.id,
  'type': subject.type,
  'name': subject.name,
  'name_cn': subject.nameCn,
  'summary': subject.summary,
  'date': subject.airDate,
  'images': subject.images,
  'tags': subject.tags.map((tag) => tag.toJson()).toList(),
  'infobox': [
    {'key': '别名', 'value': subject.alias},
  ],
  'rating': {
    'rank': subject.rank,
    'score': subject.ratingScore,
    'total': subject.votes,
    'count': subject.votesCount,
  },
  'info': subject.info,
  'meta_tags': subject.metaTags,
};

class RssException implements Exception {
  const RssException(this.message);
  final String message;
  @override
  String toString() => message;
}
