import 'dart:async';

enum TorrentTaskState {
  metadata,
  downloading,
  buffering,
  queued,
  paused,
  cancelled,
  completed,
  error,
}

class TorrentCapability {
  final bool supported;
  final bool ready;
  final String? unavailableReason;

  const TorrentCapability({
    required this.supported,
    required this.ready,
    this.unavailableReason,
  });
}

class TorrentFileInfo {
  final int index;
  final String name;
  final int size;
  final int downloadedBytes;
  final bool isVideo;

  const TorrentFileInfo({
    required this.index,
    required this.name,
    required this.size,
    this.downloadedBytes = 0,
    required this.isVideo,
  });

  Map<String, Object?> toJson() => {
    'index': index,
    'name': name,
    'size': size,
    'downloadedBytes': downloadedBytes,
    'isVideo': isVideo,
  };

  factory TorrentFileInfo.fromJson(Map<String, dynamic> json) =>
      TorrentFileInfo(
        index: json['index'] as int,
        name: json['name'] as String,
        size: json['size'] as int,
        downloadedBytes: (json['downloadedBytes'] as num?)?.toInt() ?? 0,
        isVideo: json['isVideo'] as bool? ?? false,
      );
}

class TorrentTaskSnapshot {
  final String id;
  final Uri source;
  final String title;
  final TorrentTaskState state;
  final double progress;
  final int downloadedBytes;
  final int totalBytes;
  final int downloadBytesPerSecond;
  final int uploadBytesPerSecond;
  final int peers;
  final List<TorrentFileInfo> files;
  final bool streamReady;
  final String? error;

  /// Why the app paused this task on its own; not persisted.
  final String? notice;
  final int? bangumiId;
  final double? episodeNumber;
  final String? releaseKey;
  final Map<String, dynamic>? subjectData;

  int? get subjectId => bangumiId;

  const TorrentTaskSnapshot({
    required this.id,
    required this.source,
    required this.title,
    required this.state,
    this.progress = 0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.downloadBytesPerSecond = 0,
    this.uploadBytesPerSecond = 0,
    this.peers = 0,
    this.files = const [],
    this.streamReady = false,
    this.error,
    this.notice,
    this.bangumiId,
    this.episodeNumber,
    this.releaseKey,
    this.subjectData,
  });

  TorrentTaskSnapshot copyWith({
    TorrentTaskState? state,
    double? progress,
    int? downloadedBytes,
    int? totalBytes,
    int? downloadBytesPerSecond,
    int? uploadBytesPerSecond,
    int? peers,
    List<TorrentFileInfo>? files,
    bool? streamReady,
    String? error,
    bool clearError = false,
    String? notice,
    bool clearNotice = false,
    Map<String, dynamic>? subjectData,
    int? bangumiId,
  }) => TorrentTaskSnapshot(
    id: id,
    source: source,
    title: title,
    state: state ?? this.state,
    progress: progress ?? this.progress,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    downloadBytesPerSecond:
        downloadBytesPerSecond ?? this.downloadBytesPerSecond,
    uploadBytesPerSecond: uploadBytesPerSecond ?? this.uploadBytesPerSecond,
    peers: peers ?? this.peers,
    files: files ?? this.files,
    streamReady: streamReady ?? this.streamReady,
    error: clearError ? null : error ?? this.error,
    notice: clearNotice ? null : notice ?? this.notice,
    bangumiId: bangumiId ?? this.bangumiId,
    episodeNumber: episodeNumber,
    releaseKey: releaseKey,
    subjectData: subjectData ?? this.subjectData,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'source': source.toString(),
    'title': title,
    'state': state.name,
    'progress': progress,
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    'files': files.map((f) => f.toJson()).toList(),
    'bangumiId': bangumiId,
    'episodeNumber': episodeNumber,
    'releaseKey': releaseKey,
    'subjectData': subjectData,
  };

  factory TorrentTaskSnapshot.fromJson(Map<String, dynamic> json) =>
      TorrentTaskSnapshot(
        id: json['id'] as String,
        source: Uri.parse(json['source'] as String),
        title: json['title'] as String,
        state: TorrentTaskState.values.firstWhere(
          (state) => state.name == json['state'],
          orElse: () => TorrentTaskState.paused,
        ),
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        downloadedBytes: (json['downloadedBytes'] as num?)?.toInt() ?? 0,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
        files: ((json['files'] as List?) ?? [])
            .map(
              (f) =>
                  TorrentFileInfo.fromJson(Map<String, dynamic>.from(f as Map)),
            )
            .toList(),
        bangumiId: json['bangumiId'] as int?,
        episodeNumber: (json['episodeNumber'] as num?)?.toDouble(),
        releaseKey: json['releaseKey'] as String?,
        subjectData: json['subjectData'] is Map
            ? Map<String, dynamic>.from(json['subjectData'] as Map)
            : null,
      );
}

class TorrentPlaybackLease {
  final Uri _url;
  final Uri Function()? _currentUrl;
  Uri get url => _currentUrl?.call() ?? _url;
  final String taskId;
  final int fileIndex;
  final Future<void> Function() _release;
  Future<void>? _closing;

  TorrentPlaybackLease({
    required Uri url,
    Uri Function()? currentUrl,
    required this.taskId,
    required this.fileIndex,
    required Future<void> Function() close,
  }) : _url = url,
       _currentUrl = currentUrl,
       _release = close;

  Future<void> close() => _closing ??= _release();
}
