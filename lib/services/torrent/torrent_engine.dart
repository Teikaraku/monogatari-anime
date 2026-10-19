import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'torrent_models.dart';

void throwIfTorrentCancelled(CancelToken? token) {
  if (token?.isCancelled == true) throw token!.cancelError!;
}

/// Metadata and payload work run outside Flutter's UI isolate.
abstract class TorrentEngine {
  Future<TorrentMetadata> resolve(Uri source, {CancelToken? cancelToken});
  Future<TorrentEngineHandle> open(
    TorrentMetadata metadata,
    Directory directory, {
    CancelToken? cancelToken,
    bool allowNetwork = true,
  });
  Future<void> dispose();
}

class TorrentMetadata {
  final String infoHash;
  final String name;
  final Uint8List bytes;
  final List<TorrentFileInfo> files;
  final int pieceLength;

  const TorrentMetadata({
    required this.infoHash,
    required this.name,
    required this.bytes,
    required this.files,
    required this.pieceLength,
  });
}

class TorrentEngineSnapshot {
  final List<TorrentFileInfo> files;
  final int downloadBytesPerSecond;
  final int uploadBytesPerSecond;
  final int peers;
  const TorrentEngineSnapshot({
    required this.files,
    this.downloadBytesPerSecond = 0,
    this.uploadBytesPerSecond = 0,
    this.peers = 0,
  });
}

abstract class TorrentEngineHandle {
  Future<TorrentEngineSnapshot> snapshot();
  Future<void> download(Set<int> fileIndices);
  Future<void> pause();
  Future<void> resume();
  Future<void> setReader(String readerId, int fileIndex, int byteOffset);
  Future<void> removeReader(String readerId);
  Future<Uint8List> read(
    String readerId,
    int fileIndex,
    int byteOffset,
    int length, {
    CancelToken? cancelToken,
  });
  Future<void> close();
}
