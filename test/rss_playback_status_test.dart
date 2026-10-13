import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/rss_playback_status.dart';
import 'package:kazumi/services/torrent/torrent_models.dart';

void main() {
  final waiting = TorrentTaskSnapshot(
    id: 'task',
    source: Uri.parse('magnet:?xt=urn:btih:fixture'),
    title: 'Fixture',
    state: TorrentTaskState.buffering,
    totalBytes: 1024,
  );

  test('distinguishes peer discovery, stalled peers and received data', () {
    expect(rssBufferingStatus(waiting), contains('寻找做种者'));
    expect(rssBufferingStatus(waiting.copyWith(peers: 2)), '等待视频分片 · 2 个连接');
    expect(
      rssBufferingStatus(
        waiting.copyWith(peers: 2, downloadBytesPerSecond: 1024),
      ),
      '正在缓冲 · 2 个连接 · 1 KB/s',
    );
    expect(
      rssBufferingStatus(waiting.copyWith(downloadedBytes: 1024)),
      '正在读取视频缓存',
    );
  });

  test('startup failure never claims a cached stream has no seeders', () {
    expect(rssStartupFailure(waiting), contains('未连接到做种者'));
    expect(
      rssStartupFailure(waiting.copyWith(peers: 1)),
      contains('未收到可播放的视频分片'),
    );
    expect(
      rssStartupFailure(waiting.copyWith(streamReady: true)),
      contains('视频分片下载或解码超时'),
    );
    expect(
      rssStartupFailure(waiting.copyWith(downloadedBytes: 1024)),
      isNot(contains('未连接到做种者')),
    );
    expect(
      rssStartupFailure(waiting.copyWith(state: TorrentTaskState.paused)),
      contains('已暂停'),
    );
  });
}
