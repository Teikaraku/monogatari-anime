import 'rss_models.dart';

/// Conservative release/filename metadata. Unknown packs never imply episode
/// numbers; file order and resolution/codec numbers are not episode identities.
RssTitleMetadata parseRssReleaseTitle(String raw) {
  final leading = RegExp(r'^\s*[\[【]([^\]】]+)[\]】]').firstMatch(raw);
  final groupMatch =
      leading != null &&
          !RegExp(
            r'^(?:\d{1,4}(?:\.\d+)?(?:v\d+)?p?|\d{1,3}\s*[-+~～－]\s*\d{1,3}(?:\s*(?:修正)?合集)?|(?:EP|SP|OVA|OAD)\s*(?:\d+(?:\.\d+)?(?:\s*[-~～－]\s*\d+)?)?)$',
            caseSensitive: false,
          ).hasMatch(leading[1]!.trim())
      ? leading
      : null;
  final group = groupMatch?.group(1)?.trim() ?? '';
  final text = raw
      .substring(groupMatch?.end ?? 0)
      .replaceFirst(
        RegExp(r'\.(?:mkv|mp4|avi|webm|mov|ts)$', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'\b20\d{2}[-/.]\d{1,2}[-/.]\d{1,2}\b'), ' ');
  final qualityMatch = RegExp(
    r'\b(2160|1440|1080|720|480)p\b',
    caseSensitive: false,
  ).firstMatch(text);
  final quality = qualityMatch != null
      ? '${qualityMatch[1]}p'
      : RegExp(
          r'\b4k\b|3840\s*[x×]\s*2160',
          caseSensitive: false,
        ).hasMatch(text)
      ? '2160p'
      : RegExp(r'1920\s*[x×]\s*1080').hasMatch(text)
      ? '1080p'
      : RegExp(r'1280\s*[x×]\s*720').hasMatch(text)
      ? '720p'
      : '';
  final special = RegExp(
    r'(?:^|[\s\[【(_-])(SP|OVA|OAD|NCOP|NCED)(?=\s*[-_.]?\s*\d|[\s\]】(_.-]|$)\s*[-_.]?\s*(\d+(?:\.\d+)?)?',
    caseSensitive: false,
  ).firstMatch(text);
  final range = RegExp(
    r'(?:^|[\s|\[【(（])(?:EP(?:ISODE)?S?\s*)?(\d{1,3})\s*[-~～－]\s*(\d{1,3})(?!\d)',
    caseSensitive: false,
  ).allMatches(text);
  for (final match in range) {
    final start = int.parse(match[1]!);
    final end = int.parse(match[2]!);
    if (start >= 1 && end > start && end <= 500 && end - start <= 200) {
      if (special != null && special.start < match.start) {
        return RssTitleMetadata(
          isBatch: true,
          isSpecial: true,
          specialKey: special[1]!.toLowerCase(),
          quality: quality,
          group: group,
        );
      }
      return RssTitleMetadata(
        episodeNumbers: List.unmodifiable([
          for (var value = start; value <= end; value++) value.toDouble(),
        ]),
        isBatch: true,
        quality: quality,
        group: group,
      );
    }
  }
  final multiple = RegExp(
    r'(?<!\w)(\d{1,3}(?:\s*\+\s*\d{1,3})+)(?!\d)',
  ).firstMatch(text);
  if (multiple != null) {
    final numbers = multiple[1]!
        .split('+')
        .map((number) => double.parse(number.trim()))
        .toSet();
    if (numbers.length > 1 &&
        numbers.every((number) => number >= 1 && number <= 500)) {
      return RssTitleMetadata(
        episodeNumbers: List.unmodifiable(numbers),
        isBatch: true,
        quality: quality,
        group: group,
      );
    }
  }
  final seasonZero = RegExp(
    r'(?<![a-zA-Z0-9])S00E(\d+)(?![a-zA-Z0-9])',
    caseSensitive: false,
  ).firstMatch(text);
  if (special != null || seasonZero != null) {
    final kind = special?[1]?.toLowerCase() ?? 'sp';
    final number = special?[2] ?? seasonZero?[1];
    final specialBatch = RegExp(
      r'(?:SP|OVA|OAD)\s*\d+\s*[-~～－]\s*\d+',
      caseSensitive: false,
    ).hasMatch(text);
    return RssTitleMetadata(
      isBatch: specialBatch,
      isSpecial: true,
      specialKey: specialBatch
          ? kind
          : '$kind${number == null ? '' : double.parse(number).toString().replaceFirst(RegExp(r'\.0$'), '')}',
      quality: quality,
      group: group,
    );
  }
  final batch = RegExp(
    r'合集|全集|全\s*\d+\s*[集话話]|\bbatch\b|\bcomplete\b',
    caseSensitive: false,
  ).hasMatch(text);
  if (batch) {
    return RssTitleMetadata(isBatch: true, quality: quality, group: group);
  }
  final episodePatterns = [
    RegExp(r'第\s*(\d+(?:\.\d+)?)\s*[集话話]'),
    RegExp(
      r'(?<![a-zA-Z0-9])S\d{1,2}E(\d+(?:\.\d+)?)(?![a-zA-Z0-9])',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(?:EP|episode)\s*(\d+(?:\.\d+)?)(?:v\d+)?\b',
      caseSensitive: false,
    ),
    RegExp(
      r'[\[【](\d+(?:\.\d+)?)(?:v\d+)?(?:\s*(?:END|Fin|完))?[\]】]',
      caseSensitive: false,
    ),
    RegExp(
      r'(?:\s[-–—]\s*|_)(\d+(?:\.\d+)?)(?:v\d+)?(?=\s|_|[\[【(]|$)',
      caseSensitive: false,
    ),
    RegExp(r'^\s*(\d{1,3})(?:v\d+)?\s*$', caseSensitive: false),
  ];
  for (final pattern in episodePatterns) {
    for (final match in pattern.allMatches(text)) {
      final number = double.tryParse(match[1]!);
      if (number != null && number >= 0 && number <= 500) {
        return RssTitleMetadata(
          episodeNumber: number,
          quality: quality,
          group: group,
        );
      }
    }
  }
  return RssTitleMetadata(quality: quality, group: group);
}
