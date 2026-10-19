import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';

void main() {
  test(
    'offline danmaku reads the storage slot independently of actual episode',
    () async {
      final downloads = _CachedDownloads()
        ..cached = [
          DanmakuEntry(
            message: '缓存弹幕',
            time: 2,
            type: 1,
            color: Colors.white,
            source: '',
          ),
        ];
      final controller = PlayerDanmakuController(
        isLocalPlayback: () => true,
        downloadController: downloads,
      );

      final result = await controller.fetchDanmaku(
        42,
        '自动播放',
        12,
        cacheEpisode: 77,
      );
      expect(downloads.reads, [(42, '自动播放', 77)]);
      expect(result.danmakus, same(downloads.cached));
      expect(result.hasDanmakus, isTrue);
    },
  );

  test(
    'an unnumbered offline special uses cache without guessing a remote episode',
    () async {
      final downloads = _CachedDownloads();
      final controller = PlayerDanmakuController(
        isLocalPlayback: () => true,
        downloadController: downloads,
      );

      final result = await controller.fetchDanmaku(
        42,
        '自动播放',
        0,
        cacheEpisode: 15,
      );
      expect(downloads.reads, [(42, '自动播放', 15)]);
      expect(result.status, DanmakuLoadStatus.empty);
      expect(result.isFailed, isFalse);
    },
  );

  test(
    'an unnumbered online special does not use a storage slot as episode number',
    () async {
      final downloads = _CachedDownloads();
      final controller = PlayerDanmakuController(
        isLocalPlayback: () => false,
        downloadController: downloads,
      );

      final result = await controller.fetchDanmaku(
        42,
        '自动播放',
        0,
        cacheEpisode: 15,
      );
      expect(downloads.reads, isEmpty);
      expect(result.status, DanmakuLoadStatus.empty);
      expect(result.isFailed, isFalse);
    },
  );
}

class _CachedDownloads implements DownloadController {
  List<DanmakuEntry>? cached;
  final reads = <(int, String, int)>[];

  @override
  Future<List<DanmakuEntry>?> getCachedDanmakus(
    int bangumiId,
    String pluginName,
    int episodeNumber,
  ) async {
    reads.add((bangumiId, pluginName, episodeNumber));
    return cached;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('unexpected download operation: ${invocation.memberName}');
}
