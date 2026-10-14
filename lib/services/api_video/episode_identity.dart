/// Shared identities for sources that describe the same numbered extra using
/// SP/特别篇/特典 aliases. Unknown titles stay distinct instead of being guessed.
String specialEpisodeKey(String label) {
  final text = label.toLowerCase().replaceAll(RegExp(r'[\s_.：:\-]+'), '');
  final match = RegExp(
    r'^(sp|special|特别篇?|特別篇?|特典|番外篇?|ova|oad|ncop|nced|op|ed|pv|预告|預告)(\d*)$',
  ).firstMatch(text);
  if (match == null) return 'special:$text';
  final type = switch (match[1]) {
    'special' ||
    '特别' ||
    '特别篇' ||
    '特別' ||
    '特別篇' ||
    '特典' ||
    '番外' ||
    '番外篇' => 'sp',
    '预告' || '預告' => 'pv',
    final value => value!,
  };
  final number = int.tryParse(match[2]!);
  return 'special:$type:${number ?? 1}';
}

String canonicalEpisodeKey(String key) {
  if (RegExp(r'^special:[a-z]+:\d+$').hasMatch(key)) return key;
  if (key.startsWith('rss-special:')) {
    return specialEpisodeKey(key.substring('rss-special:'.length));
  }
  if (key.startsWith('special:')) {
    return specialEpisodeKey(key.substring('special:'.length));
  }
  return key;
}

String canonicalEpisodePageUrl(String pageUrl) {
  final uri = Uri.tryParse(pageUrl);
  if (uri == null ||
      uri.scheme != 'monogatari' ||
      uri.host != 'episode' ||
      uri.pathSegments.length != 2) {
    return pageUrl;
  }
  return 'monogatari://episode/${uri.pathSegments.first}/${Uri.encodeComponent(canonicalEpisodeKey(uri.pathSegments.last))}';
}

/// Main episodes keep their season number. Extras and fractional episodes have
/// a deterministic separate slot, independent of a source catalog's position.
int episodeHistorySlot(String pageUrl, int legacySlot) {
  final uri = Uri.tryParse(canonicalEpisodePageUrl(pageUrl));
  if (uri == null ||
      uri.scheme != 'monogatari' ||
      uri.host != 'episode' ||
      uri.pathSegments.length != 2) {
    return legacySlot;
  }
  final key = uri.pathSegments.last;
  final number = int.tryParse(key);
  if (number != null && number > 0 && number < 1000000) return number;
  var hash = 2166136261;
  for (final value in key.codeUnits) {
    hash = ((hash ^ value) * 16777619) & 0x7fffffff;
  }
  return 1000000 + hash;
}
