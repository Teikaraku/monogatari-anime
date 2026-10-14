import 'package:kazumi/utils/m3u8_parser.dart';

class M3u8AdFilter {
  /// Filter ad segments from a media playlist.
  /// Mimics FFmpeg hls_ad_filter behavior using discontinuity groups.
  static List<M3u8Segment> filterAds(List<M3u8Segment> segments) {
    if (segments.isEmpty) return segments;

    // Group segments by discontinuityGroup
    final groups = <int, List<M3u8Segment>>{};
    for (final seg in segments) {
      groups.putIfAbsent(seg.discontinuityGroup, () => []);
      groups[seg.discontinuityGroup]!.add(seg);
    }

    // Only one group means no ads detected
    if (groups.length <= 1) return segments;

    // Calculate total duration per group
    final groupDurations = <int, double>{};
    for (final entry in groups.entries) {
      groupDurations[entry.key] = entry.value.fold<double>(
        0.0,
        (sum, seg) => sum + seg.duration,
      );
    }

    // Find the longest group as the "main content" reference
    double maxDuration = 0;
    for (final d in groupDurations.values) {
      if (d > maxDuration) maxDuration = d;
    }

    // Identify ad groups
    final adGroups = <int>{};
    final sortedKeys = groups.keys.toList()..sort();

    for (final groupId in sortedKeys) {
      final groupDuration = groupDurations[groupId]!;

      // Skip the main content group
      if (groupDuration == maxDuration) continue;

      bool isAd = false;

      // A discontinuity can split genuine content into two long chapters.
      // Relative size alone must never remove several minutes of the episode.
      if (groupDuration <= 60 && groupDuration < maxDuration * 0.15) {
        isAd = true;
      }

      // First or last group with short duration (< 30s)
      if ((groupId == sortedKeys.first || groupId == sortedKeys.last) &&
          groupDuration < 30.0) {
        isAd = true;
      }

      // Very short segments (< 10s) are almost certainly ads
      if (groupDuration < 10.0) {
        isAd = true;
      }

      if (isAd) {
        adGroups.add(groupId);
      }
    }

    if (adGroups.isEmpty) return segments;

    // Remove ad segments
    return segments
        .where((seg) => !adGroups.contains(seg.discontinuityGroup))
        .toList();
  }

  /// Preserve the original playlist metadata and original AES sequence IVs.
  /// Byte-range playlists retain their layout because omitted implicit byte
  /// offsets require a separate remuxing step rather than simple filtering.
  static String filterPlaylist(String content, String baseUrl) {
    if (M3u8Parser.detectType(content) == M3u8Type.master ||
        content.contains('#EXT-X-BYTERANGE'))
      return content;
    final parsed = M3u8Parser.parseMediaPlaylist(content, baseUrl);
    final retained = filterAds(parsed.segments).toSet();
    if (retained.length == parsed.segments.length) return content;
    final lines = content.split('\n');
    final out = <String>[];
    var index = 0;
    var skipping = false;
    String? currentMap;
    String? writtenMap;
    for (final line in lines) {
      final text = line.trim();
      if (text.startsWith('#EXT-X-KEY:')) continue;
      if (text.startsWith('#EXT-X-MAP:')) {
        currentMap = line;
        continue;
      }
      if (text.startsWith('#EXTINF:')) {
        skipping = !retained.contains(parsed.segments[index]);
        if (skipping) continue;
        if (currentMap != null && currentMap != writtenMap) {
          out.add(currentMap);
          writtenMap = currentMap;
        }
        final key = parsed.segments[index].key;
        out.add(key?.toString() ?? '#EXT-X-KEY:METHOD=NONE');
      } else if (text.isNotEmpty && !text.startsWith('#')) {
        if (!skipping) out.add(line);
        index++;
        skipping = false;
        continue;
      }
      if (!skipping || text.startsWith('#EXT-X-DISCONTINUITY')) out.add(line);
    }
    return out.join('\n');
  }

  /// Calculate the new target duration after filtering
  static double calculateTargetDuration(List<M3u8Segment> segments) {
    if (segments.isEmpty) return 0;
    double maxSegDuration = 0;
    for (final seg in segments) {
      if (seg.duration > maxSegDuration) {
        maxSegDuration = seg.duration;
      }
    }
    return maxSegDuration;
  }
}
