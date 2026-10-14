import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:b_encode_decode/b_encode_decode.dart' as bencode;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dtorrent_task_v2/dtorrent_task_v2.dart' as bt;
import 'package:path/path.dart' as p;
import 'package:kazumi/services/network/mikan_http_adapter.dart';

import 'torrent_engine.dart';
import 'torrent_models.dart';

const _metadataLimit = 16 * 1024 * 1024;

typedef TorrentWorkerSpawner =
    Future<Isolate> Function(
      void Function(List<dynamic>) entry,
      List<dynamic> arguments, {
      required SendPort onError,
      required SendPort onExit,
    });

/// The BT scheduler, metadata parser, file IO and hashing live in one isolate.
/// Native libraries and remote streaming servers are not needed.
class DartTorrentEngine implements TorrentEngine {
  final bool allowLoopbackPeers;
  final String? Function(Uri)? metadataProxy;
  final TorrentWorkerSpawner? workerSpawner;

  /// Upload cap in bytes per second, read when a task opens and on every
  /// snapshot so a changed setting applies within a second. Null is unlimited.
  final int? Function()? uploadLimit;
  Isolate? _isolate;
  SendPort? _port;
  ReceivePort? _receive;
  ReceivePort? _errors;
  ReceivePort? _exits;
  int _generation = 0;
  Future<void>? _starting;
  final _pending = <int, Completer<dynamic>>{};
  int _nextRequest = 0;
  bool _disposed = false;

  DartTorrentEngine({
    this.allowLoopbackPeers = false,
    this.metadataProxy,
    this.workerSpawner,
    this.uploadLimit,
  });

  Future<void> _start() => _starting ??= _spawn().catchError((Object error) {
    _starting = null;
    _receive?.close();
    _errors?.close();
    _exits?.close();
    throw error;
  });

  Future<void> _spawn() async {
    if (_disposed) throw StateError('Torrent engine is closed');
    final receive = _receive = ReceivePort();
    final errors = _errors = ReceivePort();
    final exits = _exits = ReceivePort();
    final generation = ++_generation;
    final ready = Completer<void>();
    ready.future.ignore();
    void failed(Object error) {
      if (_disposed || generation != _generation) return;
      if (!ready.isCompleted) ready.completeError(error);
      _port = null;
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _starting = null;
      _generation++;
      receive.close();
      errors.close();
      exits.close();
      for (final pending in _pending.values) {
        pending.completeError(error);
      }
      _pending.clear();
    }

    errors.listen((dynamic error) => failed(StateError('BT 后台引擎异常退出')));
    exits.listen((dynamic _) => failed(StateError('BT 后台引擎已停止，请重试')));
    receive.listen((dynamic message) {
      final map = message as Map;
      if (map['port'] != null) {
        _port = map['port'] as SendPort;
        ready.complete();
        return;
      }
      final completer = _pending.remove(map['id']);
      if (completer == null) return;
      if (map['error'] != null) {
        completer.completeError(StateError(map['error'] as String));
      } else {
        final result = map['result'];
        completer.complete(
          result is TransferableTypedData
              ? result.materialize().asUint8List()
              : result,
        );
      }
    });
    final arguments = [receive.sendPort, allowLoopbackPeers];
    _isolate = workerSpawner == null
        ? await Isolate.spawn(
            _torrentWorker,
            arguments,
            onError: errors.sendPort,
            onExit: exits.sendPort,
            errorsAreFatal: true,
          )
        : await workerSpawner!(
            _torrentWorker,
            arguments,
            onError: errors.sendPort,
            onExit: exits.sendPort,
          );
    await ready.future;
  }

  Future<dynamic> _call(
    String command,
    Map<String, dynamic> arguments, {
    CancelToken? cancelToken,
  }) async {
    throwIfTorrentCancelled(cancelToken);
    await _start();
    if (_disposed) throw StateError('Torrent engine is closed');
    final id = _nextRequest++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _port!.send({'id': id, 'command': command, 'arguments': arguments});
    final cancellation = cancelToken?.whenCancel.asStream().listen((_) {
      if (_pending.containsKey(id)) _port?.send({'cancel': id});
    });
    try {
      final result = await completer.future;
      throwIfTorrentCancelled(cancelToken);
      return result;
    } catch (_) {
      throwIfTorrentCancelled(cancelToken);
      rethrow;
    } finally {
      await cancellation?.cancel();
    }
  }

  @override
  Future<TorrentMetadata> resolve(
    Uri source, {
    CancelToken? cancelToken,
  }) async {
    final map = Map<String, dynamic>.from(
      await _call('metadata', {
            'source': source.toString(),
            'proxy': metadataProxy?.call(source),
          }, cancelToken: cancelToken)
          as Map,
    );
    return TorrentMetadata(
      infoHash: map['hash'] as String,
      name: map['name'] as String,
      bytes: map['bytes'] as Uint8List,
      pieceLength: map['pieceLength'] as int,
      files: (map['files'] as List)
          .map(
            (f) =>
                TorrentFileInfo.fromJson(Map<String, dynamic>.from(f as Map)),
          )
          .toList(),
    );
  }

  @override
  Future<TorrentEngineHandle> open(
    TorrentMetadata metadata,
    Directory directory, {
    CancelToken? cancelToken,
    bool allowNetwork = true,
  }) async {
    await _start();
    final generation = _generation;
    await _call('open', {
      'hash': metadata.infoHash,
      'bytes': metadata.bytes,
      'directory': directory.path,
      'allowNetwork': allowNetwork,
      'uploadLimit': uploadLimit?.call(),
    }, cancelToken: cancelToken);
    if (generation != _generation) throw StateError('BT 后台引擎已停止，请重试');
    return _DartTorrentHandle(this, metadata.infoHash, generation);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    if (_port != null) await _call('shutdown', {});
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _receive?.close();
    _errors?.close();
    _exits?.close();
    for (final future in _pending.values) {
      future.completeError(StateError('Torrent engine is closed'));
    }
    _pending.clear();
  }
}

class _DartTorrentHandle implements TorrentEngineHandle {
  final DartTorrentEngine engine;
  final String hash;
  final int generation;
  bool closed = false;
  Future<void>? _closing;
  _DartTorrentHandle(this.engine, this.hash, this.generation);
  Future<dynamic> call(
    String command, [
    Map<String, dynamic> args = const {},
    CancelToken? cancelToken,
  ]) {
    if (closed) throw StateError('Torrent task is closed');
    if (generation != engine._generation) throw StateError('BT 后台任务已失效，请重试');
    return engine._call(command, {
      'hash': hash,
      ...args,
    }, cancelToken: cancelToken);
  }

  @override
  Future<TorrentEngineSnapshot> snapshot() async {
    final map =
        await call('snapshot', {'uploadLimit': engine.uploadLimit?.call()})
            as Map;
    return TorrentEngineSnapshot(
      files: (map['files'] as List)
          .map(
            (f) =>
                TorrentFileInfo.fromJson(Map<String, dynamic>.from(f as Map)),
          )
          .toList(),
      downloadBytesPerSecond: map['downloadSpeed'] as int,
      uploadBytesPerSecond: map['uploadSpeed'] as int,
      peers: map['peers'] as int,
    );
  }

  @override
  Future<void> download(Set<int> fileIndices) async {
    await call('download', {'files': fileIndices.toList()});
  }

  @override
  Future<void> pause() async {
    await call('pause');
  }

  @override
  Future<void> resume() async {
    await call('resume');
  }

  @override
  Future<void> setReader(String readerId, int fileIndex, int byteOffset) async {
    await call('reader', {
      'reader': readerId,
      'file': fileIndex,
      'offset': byteOffset,
    });
  }

  @override
  Future<void> removeReader(String readerId) async {
    await call('removeReader', {'reader': readerId});
  }

  @override
  Future<Uint8List> read(
    String readerId,
    int fileIndex,
    int byteOffset,
    int length, {
    CancelToken? cancelToken,
  }) async =>
      await call('read', {
            'reader': readerId,
            'file': fileIndex,
            'offset': byteOffset,
            'length': length,
          }, cancelToken)
          as Uint8List;
  @override
  Future<void> close() => _closing ??= _closeHandle();

  Future<void> _closeHandle() async {
    if (closed) return;
    if (generation != engine._generation) {
      closed = true;
      return;
    }
    await call('close');
    closed = true;
  }
}

void _torrentWorker(List<dynamic> arguments) {
  bt.MetadataDownloader.cacheEnabled = false;
  final output = arguments[0] as SendPort;
  final worker = _TorrentWorker(arguments[1] as bool);
  final commands = ReceivePort();
  output.send({'port': commands.sendPort});
  commands.listen((dynamic raw) async {
    final message = raw as Map;
    if (message.containsKey('cancel')) {
      worker.cancel(message['cancel'] as int);
      return;
    }
    final id = message['id'] as int;
    try {
      final result = await worker.dispatch(
        id,
        message['command'] as String,
        Map<String, dynamic>.from(message['arguments'] as Map),
      );
      // Copy only the delivered range into a transferable buffer, rather than
      // sending a view backed by a whole verified piece across isolates.
      output.send({
        'id': id,
        'result': message['command'] == 'read'
            ? TransferableTypedData.fromList([result as Uint8List])
            : result,
      });
    } catch (error) {
      output.send({'id': id, 'error': error.toString()});
    } finally {
      worker.finished(id);
    }
  });
}

class _TorrentWorker {
  final bool allowLoopbackPeers;
  final tasks = <String, _WorkerTask>{};
  final cancellations = <int, CancelToken>{};
  _TorrentWorker(this.allowLoopbackPeers);
  void cancel(int id) =>
      cancellations[id]?.cancel('Torrent operation cancelled');
  void finished(int id) => cancellations.remove(id);

  Future<dynamic> dispatch(
    int id,
    String command,
    Map<String, dynamic> args,
  ) async {
    final token = cancellations[id] = CancelToken();
    if (command == 'metadata') {
      return _resolve(
        Uri.parse(args['source'] as String),
        token,
        args['proxy'] as String?,
      );
    }
    if (command == 'open') {
      final model = _parse(args['bytes'] as Uint8List);
      if (model.infoHash != args['hash']) {
        throw const FormatException(
          'Stored torrent info hash does not match metadata',
        );
      }
      final directory = Directory(args['directory'] as String);
      await _guardTree(directory);
      final task = _WorkerTask(
        model,
        directory,
        allowLoopbackPeers,
        offline: args['allowNetwork'] == false,
        uploadLimit: args['uploadLimit'] as int?,
      );
      await task.start(token);
      tasks[args['hash'] as String] = task;
      return null;
    }
    if (command == 'shutdown') {
      for (final task in tasks.values) {
        await task.close();
      }
      tasks.clear();
      return null;
    }
    final task = tasks[args['hash']];
    if (task == null) throw StateError('Torrent task does not exist');
    switch (command) {
      case 'snapshot':
        task.applyUploadLimit(args['uploadLimit'] as int?);
        return task.snapshot();
      case 'download':
        task.downloads = Set<int>.from(args['files'] as List);
        task.applyPriorities();
        return null;
      case 'pause':
        await task.pause();
        return null;
      case 'resume':
        task.paused = false;
        task.applyPriorities();
        return null;
      case 'reader':
        task.readers[args['reader'] as String] = (
          args['file'] as int,
          args['offset'] as int,
        );
        task.applyPriorities();
        return null;
      case 'removeReader':
        task.readers.remove(args['reader']);
        task.applyPriorities();
        return null;
      case 'read':
        return task.read(
          args['reader'] as String,
          args['file'] as int,
          args['offset'] as int,
          args['length'] as int,
          token,
        );
      case 'close':
        await task.close();
        tasks.remove(args['hash']);
        return null;
      default:
        throw ArgumentError('Unknown torrent operation');
    }
  }

  Future<Map<String, dynamic>> _resolve(
    Uri source,
    CancelToken token,
    String? proxy,
  ) async {
    Uint8List bytes;
    if (source.scheme == 'magnet') {
      final magnet = bt.MagnetParser.parse(source.toString());
      if (magnet == null) throw const FormatException('Invalid v1 magnet link');
      final downloader = bt.MetadataDownloader.fromMagnet(source.toString());
      if (allowLoopbackPeers) {
        downloader.ignoreIps.remove(InternetAddress.loopbackIPv4);
      }
      final result = Completer<Uint8List>();
      final listener = downloader.createListener()
        ..on<bt.MetaDataDownloadComplete>((event) {
          if (!result.isCompleted) {
            result.complete(Uint8List.fromList(event.data));
          }
        })
        ..on<bt.MetaDataDownloadFailed>((event) {
          if (!result.isCompleted) {
            result.completeError(StateError(event.error));
          }
        });
      unawaited(
        downloader.startDownload().catchError((Object error) {
          if (!result.isCompleted) result.completeError(error);
        }),
      );
      try {
        final info = await Future.any<Uint8List>([
          result.future,
          token.whenCancel.then((error) => throw error),
        ]).timeout(const Duration(seconds: 120));
        if (info.length > _metadataLimit ||
            sha1.convert(info).toString() != magnet.infoHashString) {
          throw const FormatException(
            'Torrent metadata hash does not match the magnet link',
          );
        }
        final prefix = bencode.encode({
          'announce-list': magnet.trackers
              .map((uri) => [uri.toString()])
              .toList(),
        });
        bytes = Uint8List.fromList([
          ...prefix.sublist(0, prefix.length - 1),
          ...'4:info'.codeUnits,
          ...info,
          101,
        ]);
      } finally {
        listener.dispose();
        await downloader.stop();
      }
    } else if (source.scheme == 'https' || source.scheme == 'http') {
      if (source.userInfo.isNotEmpty || source.host.isEmpty) {
        throw const FormatException('Invalid torrent URL');
      }
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          if (proxy != null) {
            final uri = Uri.parse(proxy);
            if (uri.scheme != 'http' && uri.scheme != 'https') {
              throw const FormatException('Unsupported torrent metadata proxy');
            }
            client.findProxy = (_) => 'PROXY ${uri.host}:${uri.port}';
            if (uri.userInfo.isNotEmpty) {
              final credentials = uri.userInfo.split(':');
              client.addProxyCredentials(
                uri.host,
                uri.port,
                '',
                HttpClientBasicCredentials(
                  Uri.decodeComponent(credentials.first),
                  Uri.decodeComponent(credentials.skip(1).join(':')),
                ),
              );
            }
          }
          return client;
        },
      );
      if (MikanHttpAdapter.supports(source)) {
        dio.httpClientAdapter = MikanHttpAdapter(
          fallback: dio.httpClientAdapter,
          proxyForUri: (_) => proxy == null ? null : Uri.parse(proxy),
        );
      }
      try {
        final response = await dio.get<ResponseBody>(
          source.toString(),
          options: Options(responseType: ResponseType.stream),
          cancelToken: token,
        );
        final content = BytesBuilder(copy: false);
        await for (final block in response.data!.stream) {
          throwIfTorrentCancelled(token);
          if (content.length + block.length > _metadataLimit) {
            throw const FormatException('Torrent metadata is too large');
          }
          content.add(block);
        }
        bytes = content.takeBytes();
      } finally {
        dio.close(force: true);
      }
    } else {
      throw const FormatException('Use a magnet link or HTTP torrent URL');
    }
    throwIfTorrentCancelled(token);
    final model = _parse(bytes);
    return {
      'hash': model.infoHash,
      'name': model.name,
      'bytes': bytes,
      'pieceLength': model.pieceLength,
      'files': _files(model).map((f) => f.toJson()).toList(),
    };
  }
}

bt.TorrentModel _parse(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > _metadataLimit) {
    throw const FormatException('Invalid torrent metadata size');
  }
  final model = bt.TorrentParser.parseBytes(bytes);
  // This engine's persistent state and piece map require SHA-1 v1 pieces.
  if (model.version != bt.TorrentVersion.v1 || model.pieces == null) {
    throw const FormatException(
      'BitTorrent v2 resources are not supported by this engine',
    );
  }
  _guardRelativePath(model.name);
  if (model.files.isEmpty ||
      model.files.length > 10000 ||
      model.totalSize <= 0 ||
      model.pieceLength > 16 * 1024 * 1024 ||
      model.pieces!.length !=
          (model.totalSize + model.pieceLength - 1) ~/ model.pieceLength) {
    throw const FormatException('Invalid torrent file or piece layout');
  }
  final paths = <String>{};
  var offset = 0;
  for (final file in model.files) {
    _guardRelativePath(file.path);
    if (file.length < 0 ||
        file.offset != offset ||
        file.symlinkPath != null ||
        file.attributes?.isSymlink == true ||
        !paths.add(file.path.toLowerCase())) {
      throw const FormatException('Unsafe torrent file layout');
    }
    offset += file.length;
  }
  return model;
}

void _guardRelativePath(String path) {
  if (path.isEmpty ||
      path.contains('\\') ||
      path.contains(':') ||
      path.contains(RegExp(r'[\x00-\x1f]')) ||
      p.posix.isAbsolute(path) ||
      path
          .split('/')
          .any(
            (part) =>
                part.isEmpty ||
                part == '.' ||
                part == '..' ||
                part.endsWith('.') ||
                part.endsWith(' ') ||
                RegExp(
                  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
                  caseSensitive: false,
                ).hasMatch(part),
          )) {
    throw const FormatException('Unsafe torrent file path');
  }
}

Future<void> _guardTree(Directory directory) async {
  final absolute = p.normalize(p.absolute(directory.path));
  var cursor = absolute;
  while (true) {
    if (await FileSystemEntity.type(cursor, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException(
        'Torrent storage contains a symbolic link',
      );
    }
    final parent = p.dirname(cursor);
    if (parent == cursor) break;
    cursor = parent;
  }
  await directory.create(recursive: true);
  await for (final entry in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (!p.isWithin(absolute, p.normalize(p.absolute(entry.path))) ||
        entry is Link) {
      throw const FileSystemException(
        'Torrent storage contains an unsafe link',
      );
    }
  }
}

List<TorrentFileInfo> _files(bt.TorrentModel model) =>
    List.generate(model.files.length, (index) {
      final file = model.files[index];
      return TorrentFileInfo(
        index: index,
        name: file.path,
        size: file.length,
        isVideo:
            !file.isPaddingFile &&
            const [
              '.mp4',
              '.mkv',
              '.webm',
              '.avi',
              '.mov',
              '.m4v',
              '.ts',
            ].contains(p.posix.extension(file.path).toLowerCase()),
      );
    });

class _WorkerTask {
  final bt.TorrentModel model;
  final Directory directory;
  final bool allowLoopbackPeers;
  final bool offline;
  late bt.TorrentTask task;
  bool _created = false;
  int? uploadLimit;
  Set<int> downloads = {};
  final readers = <String, (int, int)>{};
  bool paused = false;
  bool closed = false;
  Future<void>? _closing;
  final verified = <int>{};
  static const _pieceCacheLimit = 4 * 1024 * 1024;
  final _pieceCache = <int, Uint8List>{};
  final _verificationFlights = <int, Future<Uint8List>>{};
  int _pieceCacheBytes = 0;
  Object? _failure;
  Completer<void> _piecesChanged = Completer<void>();

  void _notifyReadiness() {
    final previous = _piecesChanged;
    _piecesChanged = Completer<void>();
    if (!previous.isCompleted) previous.complete();
  }

  _WorkerTask(
    this.model,
    this.directory,
    this.allowLoopbackPeers, {
    this.offline = false,
    this.uploadLimit,
  });

  void applyUploadLimit(int? value) {
    if (value == uploadLimit) return;
    uploadLimit = value;
    if (_created) task.setUploadRateLimit(value);
  }

  Future<void> start(CancelToken token) async {
    // Validate persisted pieces before the scheduler trusts the resume bitfield.
    final state = await bt.StateFileV2.getStateFile(directory.path, model);
    try {
      for (final moved in state.movedFilePaths.values) {
        if (!p.isWithin(directory.path, p.absolute(moved))) {
          throw const FileSystemException('Unsafe moved torrent file');
        }
      }
      for (final piece in List<int>.from(state.bitfield.completedPieces)) {
        throwIfTorrentCancelled(token);
        final content = await _readPersistedPiece(piece);
        if (content == null || !_hashMatches(piece, content)) {
          await state.updateBitfield(piece, false);
        } else {
          verified.add(piece);
        }
      }
    } finally {
      await state.close();
    }
    throwIfTorrentCancelled(token);
    if (offline) return;
    task = bt.TorrentTask.newTask(model, directory.path, true);
    _created = true;
    task.setLocalDiscoveryEnabled(false);
    task.setUploadRateLimit(uploadLimit);
    Object? startupError;
    final starting = task
        .start(startPaused: true, allowLoopbackPeers: allowLoopbackPeers)
        .catchError((Object error) {
          startupError = error;
          return <String, dynamic>{};
        });
    try {
      // The scheduler starts paused; no payload is requested before selection.
      while (task.pieceManager == null || task.fileManager == null) {
        throwIfTorrentCancelled(token);
        if (startupError != null) throw startupError!;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      task.fileManager!.events.on<bt.SubPieceWriteFailed>((event) {
        _failure = const FileSystemException('无法写入视频分片，请检查磁盘剩余空间和目录权限');
        _notifyReadiness();
      });
      task.fileManager!.events.on<bt.StateFileUpdated>(
        (_) => _notifyReadiness(),
      );
      task.pieceManager!.pieceSelector.setSkippedPieces(
        List.generate(model.pieces!.length, (i) => i),
      );
      await Future.any([
        starting,
        token.whenCancel.then((error) => throw error),
      ]);
      if (startupError != null) throw startupError!;
      throwIfTorrentCancelled(token);
    } catch (_) {
      await close();
      rethrow;
    }
  }

  bool _hashMatches(int piece, List<int> content) =>
      sha1.convert(content).bytes.toString() == model.pieces![piece].toString();

  Future<Uint8List?> _readPersistedPiece(int piece) async {
    final begin = piece * model.pieceLength;
    final end = min(model.totalSize, begin + model.pieceLength);
    final data = BytesBuilder(copy: false);
    for (final file in model.files) {
      final left = max(begin, file.offset), right = min(end, file.end);
      if (left >= right) continue;
      if (file.isPaddingFile) {
        data.add(Uint8List(right - left));
        continue;
      }
      final path = p.joinAll([directory.path, ...file.path.split('/')]);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final input = await File(path).open();
      try {
        await input.setPosition(left - file.offset);
        final block = await input.read(right - left);
        if (block.length != right - left) return null;
        data.add(block);
      } finally {
        await input.close();
      }
    }
    return data.takeBytes();
  }

  void applyPriorities() {
    _notifyReadiness();
    if (closed || offline) return;
    final wanted = <int>{};
    for (final index in downloads) {
      final file = model.files[index];
      for (
        var piece = file.offset ~/ model.pieceLength;
        piece <= (file.end - 1) ~/ model.pieceLength;
        piece++
      ) {
        wanted.add(piece);
      }
    }
    final priority = <int>{};
    // Container probing can request the header and tail concurrently. Every
    // reader's current piece outranks another reader's forward buffer.
    for (final reader in readers.values) {
      final current =
          (model.files[reader.$1].offset + reader.$2) ~/ model.pieceLength;
      priority.add(current);
    }
    final urgent = <int>{...priority};
    for (final reader in readers.values) {
      final file = model.files[reader.$1];
      final current = (file.offset + reader.$2) ~/ model.pieceLength;
      final end = (file.end - 1) ~/ model.pieceLength;
      // Finish the next short runway before a slow peer can strand its final
      // block. Hedging only the HTTP reader's current piece is already too late
      // once the decoder consumes its last few seconds of buffered packets.
      final urgentAhead = max(
        1,
        (2 * 1024 * 1024 + model.pieceLength - 1) ~/ model.pieceLength,
      );
      for (
        var piece = current;
        piece < min(current + urgentAhead, end + 1);
        piece++
      ) {
        urgent.add(piece);
      }
      // A fixed four-piece window can be only 64 KiB on small-piece torrents.
      // Bound lookahead by bytes so playback keeps a useful, temporary buffer.
      final ahead = max(
        4,
        (16 * 1024 * 1024 + model.pieceLength - 1) ~/ model.pieceLength,
      );
      for (
        var piece = current;
        piece < min(current + ahead, end + 1);
        piece++
      ) {
        priority.add(piece);
        wanted.add(piece);
      }
    }
    task.pieceManager!.pieceSelector.setPriorityPieces(priority);
    task.pieceManager!.pieceSelector.setSkippedPieces([
      for (var index = 0; index < model.pieces!.length; index++)
        if (!wanted.contains(index)) index,
    ]);
    task.setStreamingUrgentPieces(urgent, wantedPieces: wanted);
    if (paused || wanted.isEmpty) {
      task.setStreamingUrgentPieces(const []);
      task.pause();
    } else {
      task.resume();
      for (final peer in task.activePeers ?? <bt.Peer>[]) {
        if (!peer.chokeMe && !peer.isDisposed) task.requestPieces(peer);
      }
    }
  }

  Map<String, dynamic> snapshot() {
    if (_failure != null) throw _failure!;
    final manager = offline ? null : task.fileManager;
    final files = _files(model).map((file) {
      final meta = model.files[file.index];
      var downloaded = 0;
      for (
        var piece = meta.offset ~/ model.pieceLength;
        piece <= (meta.end - 1) ~/ model.pieceLength;
        piece++
      ) {
        if (offline
            ? verified.contains(piece)
            : manager?.localHave(piece) == true) {
          downloaded +=
              min(meta.end, (piece + 1) * model.pieceLength) -
              max(meta.offset, piece * model.pieceLength);
        }
      }
      return TorrentFileInfo(
        index: file.index,
        name: file.name,
        size: file.size,
        isVideo: file.isVideo,
        downloadedBytes: downloaded,
      ).toJson();
    }).toList();
    // Upstream rates use bytes / millisecond.
    return {
      'files': files,
      'downloadSpeed': offline ? 0 : (task.currentDownloadSpeed * 1000).round(),
      'uploadSpeed': offline ? 0 : (task.uploadSpeed * 1000).round(),
      'peers': offline ? 0 : task.connectedPeersNumber,
    };
  }

  Future<Uint8List> read(
    String reader,
    int fileIndex,
    int offset,
    int length,
    CancelToken token,
  ) async {
    final file = model.files[fileIndex];
    if (offset < 0 ||
        length <= 0 ||
        length > 256 * 1024 ||
        offset + length > file.length) {
      throw RangeError('Invalid torrent read range');
    }
    final piece = (file.offset + offset) ~/ model.pieceLength;
    final end = min(
      length,
      (piece + 1) * model.pieceLength - file.offset - offset,
    );
    if (offline) {
      throwIfTorrentCancelled(token);
      if (closed || paused || !verified.contains(piece)) {
        throw StateError('缓存不完整，当前网络不允许下载缺少的分片');
      }
      // Startup already hashes every persisted piece. Read only the requested
      // range, avoiding a whole-piece read/hash for each 64 KiB HTTP block.
      final path = p.joinAll([directory.path, ...file.path.split('/')]);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FileSystemException('Cached torrent file is unavailable');
      }
      final input = await File(path).open();
      try {
        await input.setPosition(offset);
        final bytes = await input.read(end);
        throwIfTorrentCancelled(token);
        if (closed || paused || bytes.length != end) {
          throw const FileSystemException('Cached torrent range is incomplete');
        }
        return bytes;
      } finally {
        await input.close();
      }
    }
    final cancelWake = token.whenCancel.asStream().listen(
      (_) => _notifyReadiness(),
    );
    try {
      final previous = readers[reader];
      readers[reader] = (fileIndex, offset);
      if (previous == null ||
          previous.$1 != fileIndex ||
          (model.files[previous.$1].offset + previous.$2) ~/
                  model.pieceLength !=
              piece) {
        applyPriorities();
      }
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (!closed &&
          readers.containsKey(reader) &&
          !paused &&
          task.fileManager?.localHave(piece) != true) {
        throwIfTorrentCancelled(token);
        if (_failure != null) throw _failure!;
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('No peer delivered the requested video piece');
        }
        await _piecesChanged.future.timeout(
          deadline.difference(DateTime.now()),
          onTimeout: () => throw TimeoutException(
            'No peer delivered the requested video piece',
          ),
        );
      }
      throwIfTorrentCancelled(token);
      if (closed || paused || !readers.containsKey(reader)) {
        throw StateError('Torrent read was cancelled');
      }
      final manager = task.fileManager!;
      var content = _pieceCache.remove(piece);
      if (content != null) _pieceCache[piece] = content;
      if (content == null &&
          (!verified.contains(piece) ||
              _verificationFlights.containsKey(piece))) {
        content = await Future.any<Uint8List>([
          _verifiedPiece(piece),
          token.whenCancel.then((error) => throw error),
        ]);
      }
      throwIfTorrentCancelled(token);
      if (closed || paused || !readers.containsKey(reader)) {
        throw StateError('Torrent read was cancelled');
      }
      if (content != null) {
        final begin = file.offset + offset - piece * model.pieceLength;
        return Uint8List.sublistView(content, begin, begin + end);
      }
      final data = await Future.any<List<int>>([
        manager.files[fileIndex].requestRead(offset, end),
        token.whenCancel.then((error) => throw error),
      ]);
      if (data.length != end) {
        throw const FileSystemException('Torrent piece was not fully written');
      }
      return Uint8List.fromList(data);
    } finally {
      await cancelWake.cancel();
    }
  }

  Future<Uint8List> _verifiedPiece(int piece) =>
      _verificationFlights.putIfAbsent(piece, () async {
        try {
          final full = await task.fileManager!.readFile(
            piece,
            0,
            min(model.pieceLength, model.totalSize - piece * model.pieceLength),
          );
          if (full == null || !_hashMatches(piece, full)) {
            throw const FileSystemException(
              'Torrent piece integrity check failed',
            );
          }
          if (closed) throw StateError('Torrent task is closed');
          verified.add(piece);
          final bytes = full is Uint8List ? full : Uint8List.fromList(full);
          // Reuse the data already read for SHA-1 instead of immediately
          // reading the same range again. Memory remains bounded even when
          // head, tail and seek readers verify different pieces concurrently.
          if (bytes.length <= _pieceCacheLimit) {
            while (_pieceCacheBytes + bytes.length > _pieceCacheLimit) {
              _pieceCacheBytes -= _pieceCache
                  .remove(_pieceCache.keys.first)!
                  .length;
            }
            _pieceCache[piece] = bytes;
            _pieceCacheBytes += bytes.length;
          }
          return bytes;
        } finally {
          _verificationFlights.remove(piece);
        }
      });

  Future<void> pause() async {
    paused = true;
    _notifyReadiness();
    if (offline) return;
    task.pause();
    await _flushFiles();
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    closed = true;
    readers.clear();
    _pieceCache.clear();
    _pieceCacheBytes = 0;
    _notifyReadiness();
    if (offline) return;
    task.pause();
    await _flushFiles();
    await task.stop();
  }

  Future<void> _flushFiles() async {
    for (final file in task.fileManager?.files ?? <bt.DownloadFile>[]) {
      await file.requestFlush();
    }
  }
}
