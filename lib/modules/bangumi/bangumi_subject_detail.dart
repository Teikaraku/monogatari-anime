/// Subject fields from next.bgm.tv `/p1/subjects/{id}` that the detail page
/// shows but [BangumiItem] does not keep: the broadcast type, Bangumi's
/// official categories and the infobox.
class BangumiSubjectDetail {
  const BangumiSubjectDetail({
    required this.platform,
    required this.metaTags,
    required this.infobox,
    required this.totalEpisodes,
    required this.airWeekday,
  });

  /// Broadcast type, such as TV, WEB, OVA or 剧场版.
  final String platform;

  /// Official public tags, in Bangumi's order.
  final List<String> metaTags;
  final List<BangumiInfoboxField> infobox;

  /// Planned number of main episodes; 0 when unknown.
  final int totalEpisodes;

  /// ISO weekday of the broadcast (1 = Monday); 0 when unknown.
  final int airWeekday;

  factory BangumiSubjectDetail.fromJson(Map<String, dynamic> json) {
    final platform = json['platform'];
    final airtime = json['airtime'];
    final rawMetaTags = json['metaTags'] ?? json['meta_tags'];
    final rawInfobox = json['infobox'];
    return BangumiSubjectDetail(
      platform: switch (platform) {
        Map() => (platform['typeCN'] ?? platform['type'] ?? '').toString(),
        String() => platform,
        _ => '',
      }
          .trim(),
      metaTags: rawMetaTags is List
          ? rawMetaTags
              .whereType<String>()
              .map((tag) => tag.trim())
              .where((tag) => tag.isNotEmpty)
              .toSet()
              .toList()
          : const [],
      infobox: rawInfobox is List
          ? rawInfobox
              .whereType<Map>()
              .map((field) =>
                  BangumiInfoboxField.fromJson(Map<String, dynamic>.from(field)))
              .where((field) => field.key.isNotEmpty && field.values.isNotEmpty)
              .toList()
          : const [],
      totalEpisodes: _toInt(json['eps'] ?? json['total_episodes']),
      airWeekday: airtime is Map ? _toInt(airtime['weekday']) : 0,
    );
  }

  /// Official categories other than the broadcast type, which has its own chip.
  List<String> get categories =>
      metaTags.where((tag) => tag != platform).toList();

  BangumiInfoboxField? field(String key) {
    for (final field in infobox) {
      if (field.key == key) return field;
    }
    return null;
  }

  static int _toInt(dynamic value) => switch (value) {
        int() => value,
        num() => value.toInt(),
        String() => int.tryParse(value) ?? 0,
        _ => 0,
      };
}

class BangumiInfoboxField {
  const BangumiInfoboxField({required this.key, required this.values});

  final String key;
  final List<BangumiInfoboxValue> values;

  /// Accepts both `/p1` (`values: [{k, v}]`) and `/v0` (`value: String | [{k, v}]`).
  factory BangumiInfoboxField.fromJson(Map<String, dynamic> json) {
    final raw = json['values'] ?? json['value'];
    final values = <BangumiInfoboxValue>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          final value = (item['v'] ?? '').toString().trim();
          if (value.isEmpty) continue;
          values.add(BangumiInfoboxValue(
            label: (item['k'] ?? '').toString().trim(),
            value: value,
          ));
        } else if (item != null && item.toString().trim().isNotEmpty) {
          values.add(BangumiInfoboxValue(value: item.toString().trim()));
        }
      }
    } else if (raw != null && raw.toString().trim().isNotEmpty) {
      values.add(BangumiInfoboxValue(value: raw.toString().trim()));
    }
    return BangumiInfoboxField(
      key: (json['key'] ?? '').toString().trim(),
      values: values,
    );
  }
}

class BangumiInfoboxValue {
  const BangumiInfoboxValue({this.label = '', required this.value});

  /// Sub-label such as the site name of a link; often empty.
  final String label;
  final String value;

  Uri? get link {
    final uri = Uri.tryParse(value);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    return uri.host.isEmpty ? null : uri;
  }
}
