import 'package:kazumi/services/torrent/torrent_models.dart';

/// Website/RSS availability does not imply a reachable BitTorrent swarm.
/// Describe the stage supported by the task instead of labeling every wait as
/// downloaded video buffering.
String rssBufferingStatus(TorrentTaskSnapshot task) {
  if (task.state == TorrentTaskState.paused) {
    return '下载已暂停，可在磁力任务中继续';
  }
  if (task.state == TorrentTaskState.error) return '磁力连接异常，正在结束本次尝试';
  if (task.totalBytes > 0 && task.downloadedBytes >= task.totalBytes) {
    return '正在读取视频缓存';
  }
  if (task.peers == 0 && task.downloadBytesPerSecond == 0) {
    return '正在寻找做种者 · 暂无连接';
  }
  if (task.downloadBytesPerSecond == 0) {
    return '等待视频分片 · ${task.peers} 个连接';
  }
  final speed = (task.downloadBytesPerSecond / 1024).round();
  return '正在缓冲 · ${task.peers} 个连接 · $speed KB/s';
}

String rssStartupFailure(TorrentTaskSnapshot? task) {
  if (task?.state == TorrentTaskState.paused) {
    return '磁力任务已暂停，请在磁力任务中继续，或使用在线播放';
  }
  if (task != null &&
      task.peers == 0 &&
      task.downloadedBytes == 0 &&
      !task.streamReady) {
    return '未连接到做种者，可能暂无做种或 BT 网络不可达。可重试、更换字幕组或使用在线播放';
  }
  if (task != null && task.downloadedBytes == 0 && !task.streamReady) {
    return '已连接做种者，但未收到可播放的视频分片。可重试、更换字幕组或使用在线播放';
  }
  return '视频分片下载或解码超时，可稍后重试或使用在线播放';
}
