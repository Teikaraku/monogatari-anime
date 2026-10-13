import 'dart:convert';
import 'dart:io';

import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/download/download_media_reset.dart';
import 'package:kazumi/utils/m3u8_parser.dart';
import 'package:path/path.dart' as path;

/// A parent playlist URL can remain the same while its chosen variant,
/// segment order or ad filtering changes. Resume only the exact saved layout.
Future<void> ensureDownloadPlaylistIdentity(
  DownloadEpisode episode, {
  required String mediaUrl,
  required List<M3u8Segment> segments,
  required bool adBlockerEnabled,
}) async {
  final identity = jsonEncode({
    'mediaUrl': mediaUrl,
    'adBlocker': adBlockerEnabled,
    'segments': [
      for (final segment in segments)
        {
          'url': segment.uri,
          'duration': segment.duration,
          'key': segment.key?.uri,
          'method': segment.key?.method,
          'iv': segment.key?.iv,
        },
    ],
  });
  final file = File(
    path.join(episode.downloadDirectory, 'playlist.identity.json'),
  );
  final previous = await file.exists() ? await file.readAsString() : null;
  if (previous == identity) return;
  await resetPartialDownloadMedia(episode);
  await file.writeAsString(identity, flush: true);
}
