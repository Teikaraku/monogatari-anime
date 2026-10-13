import 'dart:io';

import 'package:kazumi/modules/download/download_module.dart';
import 'package:path/path.dart' as path;

final _downloadMediaFile = RegExp(
  r'^(?:seg_\d+\.ts(?:\.tmp)?|key_\d+\.key|playlist\.m3u8|playlist\.identity\.json|video\.mp4(?:\.tmp)?)$',
);

/// Different providers do not share segment indices or byte ranges. Remove
/// only this episode's unfinished media before switching, keeping cached
/// danmaku and unrelated files. Completed downloads are never overwritten.
Future<void> resetPartialDownloadMedia(DownloadEpisode episode) async {
  if (episode.status == DownloadStatus.completed) {
    throw StateError('不能替换已完成的下载');
  }
  final directory = episode.downloadDirectory;
  if (directory.isNotEmpty) {
    final root = Directory(directory);
    if (await root.exists()) {
      await for (final entry in root.list(followLinks: false)) {
        if (entry is File &&
            _downloadMediaFile.hasMatch(path.basename(entry.path))) {
          await entry.delete();
        }
      }
    }
  }
  episode.localM3u8Path = '';
  episode.totalSegments = 0;
  episode.downloadedSegments = 0;
  episode.totalBytes = 0;
  episode.progressPercent = 0;
  episode.completedAt = null;
}
