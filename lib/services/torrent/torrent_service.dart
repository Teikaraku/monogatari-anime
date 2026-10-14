import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/services/logging/logger.dart';

import 'dart_torrent_engine.dart';
import 'torrent_engine.dart';
import 'torrent_models.dart';

/// Persistent BT tasks and scoped playback leases. Closing a player releases
/// its readers, while an explicit download retains ownership of selected files.
class TorrentService {
  final TorrentEngine _engine;
  final Future<Directory> Function() _directoryProvider;
  final Future<bool> Function() _networkAllowed;
  final Future<HttpServer> Function() _serverBinder;
  final Duration metadataTimeout;
  final int maxActiveTasks;
  final _records = <String, _TorrentRecord>{};
  final _leases = <String, _LeaseState>{};
  final _tasksController =
      StreamController<List<TorrentTaskSnapshot>>.broadcast();
  final _capabilityController = StreamController<TorrentCapability>.broadcast();
  final _noticeController = StreamController<String>.broadcast();
  final _metadataTokens = <CancelToken>{};
  final _metadataWriters = <String, int>{};
  Directory? _directory;
  HttpServer? _server;
  Future<bool>? _serverRepair;
  final _serverKey = base64Url
      .encode(List.generate(24, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
  Timer? _timer;
  Future<void>? _initialization;
  Future<void> _saveLane = Future.value();
  Future<void> _activationLane = Future.value();
  bool _refreshing = false;
  bool _drainingDownloads = false;
  Future<void>? _drainWork;
  Future<void>? _refreshWork;
  bool _closed = false;
  var _lastPolicyCheck = DateTime.fromMillisecondsSinceEpoch(0);
  TorrentCapability _capability = const TorrentCapability(
    supported: true,
    ready: false,
  );

  TorrentService({
    TorrentEngine? engine,
    Future<Directory> Function()? directoryProvider,
    Future<bool> Function()? networkAllowed,
    Future<HttpServer> Function()? serverBinder,
    this.metadataTimeout = const Duration(seconds: 120),
    this.maxActiveTasks = 2,
  }) : _engine = engine ?? DartTorrentEngine(),
       _directoryProvider = directoryProvider ?? _defaultDirectory,
       _networkAllowed = networkAllowed ?? (() async => true),
       _serverBinder =
           serverBinder ??
           (() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)) {
    if (maxActiveTasks < 1) throw ArgumentError.value(maxActiveTasks);
  }

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    await support.create(recursive: true);
    // Resolve trusted system aliases such as iOS /var -> /private/var before
    // enforcing the no-symlink rule inside our own torrent cache subtree.
    final canonicalSupport = await support.resolveSymbolicLinks();
    return Directory(p.join(canonicalSupport, 'torrent-v1'));
  }

  TorrentCapability get capability => _capability;
  Stream<TorrentCapability> get watchCapability => _capabilityController.stream;
  List<TorrentTaskSnapshot> get tasks =>
      List.unmodifiable(_records.values.map((r) => r.snapshot));
  Stream<List<TorrentTaskSnapshot>> get watchTasks => _tasksController.stream;

  /// Things the service did on its own that the user should hear about, such
  /// as pausing a download.
  Stream<String> get notices => _noticeController.stream;
  int get inactiveCacheBytes => _records.values
      .where((r) => !r.retained && !r.explicitDownload && r.leases.isEmpty)
      .fold(0, (sum, r) => sum + r.snapshot.downloadedBytes);

  Future<void> initialize() =>
      _initialization ??= _initialize().catchError((Object error) {
        _initialization = null;
        throw error;
      });

  int get pendingMetadataCount =>
      _metadataTokens.where((token) => !token.isCancelled).length;

  void cancelPendingMetadata() {
    for (final token in _metadataTokens.toList()) {
      token.cancel('暂停全部');
    }
    _emit();
  }

  Future<void> _initialize() async {
    try {
      if (_closed) throw StateError('Torrent service is closed');
      final directory = await _directoryProvider();
      await _guardDirectory(directory);
      _directory = directory;
      final retainedIds = <String>{};
      final manifest = File(p.join(directory.path, 'tasks.json'));
      if (await manifest.exists()) {
        if (await manifest.length() > 8 * 1024 * 1024) {
          throw const FormatException('Torrent task index is too large');
        }
        final rows = jsonDecode(await manifest.readAsString()) as List;
        for (final row in rows) {
          try {
            final json = Map<String, dynamic>.from(row as Map);
            var snapshot = TorrentTaskSnapshot.fromJson(
              Map<String, dynamic>.from(json['snapshot'] as Map),
            );
            if (!_validId(snapshot.id)) continue;
            final taskDirectory = _taskDirectory(snapshot.id);
            await _guardDirectory(taskDirectory);
            // Old manifests predate temporary playback. Preserve their data.
            final retained = json['retained'] as bool? ?? true;
            final explicit = json['explicitDownload'] as bool? ?? false;
            if (retained || explicit) retainedIds.add(snapshot.id);
            if (!retained && !explicit) {
              await taskDirectory.delete(recursive: true);
              continue;
            }
            final metadataFile = File(
              p.join(taskDirectory.path, 'metadata.torrent'),
            );
            if (!await metadataFile.exists() ||
                await metadataFile.length() > 16 * 1024 * 1024) {
              continue;
            }
            final requested =
                json['downloadRequested'] as bool? ??
                (explicit &&
                    const {
                      TorrentTaskState.downloading,
                      TorrentTaskState.queued,
                    }.contains(snapshot.state));
            snapshot = snapshot.copyWith(
              state: snapshot.state == TorrentTaskState.completed
                  ? TorrentTaskState.completed
                  : requested
                  ? TorrentTaskState.queued
                  : TorrentTaskState.paused,
              streamReady: false,
            );
            _records[snapshot.id] = _TorrentRecord(
              snapshot,
              TorrentMetadata(
                infoHash: snapshot.id,
                name: snapshot.title,
                bytes: await metadataFile.readAsBytes(),
                files: snapshot.files,
                pieceLength: json['pieceLength'] as int,
              ),
              explicitDownload: explicit,
              downloadRequested: requested,
              retained: retained || explicit,
              selectedFiles: Set<int>.from(
                json['selectedFiles'] as List? ?? [],
              ),
            );
          } catch (_) {
            // A damaged task never authorizes a path or prevents other tasks restoring.
          }
        }
      }
      final taskRoot = Directory(p.join(directory.path, 'tasks'));
      if (await taskRoot.exists()) {
        await for (final entry in taskRoot.list(followLinks: false)) {
          final id = p.basename(entry.path);
          if (entry is! Directory ||
              !_validId(id) ||
              retainedIds.contains(id)) {
            continue;
          }
          if (await File(p.join(entry.path, '.temporary-playback')).exists()) {
            await _guardDirectory(entry);
            await entry.delete(recursive: true);
          }
        }
      }
      await ensurePlaybackServer();
      _capability = const TorrentCapability(supported: true, ready: true);
      _capabilityController.add(_capability);
      await _save();
      _emit();
      _scheduleDownloads();
    } catch (error) {
      _timer?.cancel();
      _timer = null;
      await _server?.close(force: true);
      _server = null;
      _records.clear();
      _capability = TorrentCapability(
        supported: true,
        ready: false,
        unavailableReason: error.toString(),
      );
      _capabilityController.add(_capability);
      rethrow;
    }
  }

  Future<void> _assertNetwork() async {
    if (_closed) throw StateError('Torrent service is closed');
    if (!await _networkAllowed()) {
      throw StateError('当前网络不允许 BT 下载，请连接 Wi-Fi 或关闭仅 Wi-Fi 下载设置');
    }
  }

  /// Returns true when the listener was replaced. Existing leases and BT work
  /// survive replacement; callers reopen the player with the lease's new URL.
  Future<bool> ensurePlaybackServer({bool checkConnection = false}) {
    if (_closed) throw StateError('Torrent service is closed');
    return _serverRepair ??= _repairPlaybackServer(
      checkConnection,
    ).whenComplete(() => _serverRepair = null);
  }

  Future<bool> _repairPlaybackServer(bool checkConnection) async {
    final previous = _server;
    if (previous != null) {
      if (!checkConnection) return false;
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        final request = await client
            .openUrl(
              'HEAD',
              Uri.parse('http://127.0.0.1:${previous.port}/health/$_serverKey'),
            )
            .timeout(const Duration(seconds: 1));
        final response = await request.close().timeout(
          const Duration(seconds: 1),
        );
        if (response.statusCode != HttpStatus.noContent ||
            response.headers.value('x-monogatari-server') != _serverKey) {
          throw const HttpException('Local playback listener identity changed');
        }
        await response.drain<void>().timeout(const Duration(seconds: 1));
        if (!_closed && identical(_server, previous)) return false;
      } catch (_) {
        await previous.close(force: true);
      } finally {
        client.close(force: true);
      }
    }
    if (_closed) throw StateError('Torrent service is closed');
    // A closed socket can leave a piece read waiting in the BT isolate. Wake
    // those readers before the native player is stopped, keeping leases and
    // downloaded pieces alive for reopening on the replacement listener.
    for (final lease in _leases.values) {
      for (final token in lease.requests.values) {
        token.cancel('Local playback listener replaced');
      }
    }
    final server = await _serverBinder();
    if (_closed) {
      await server.close(force: true);
      throw StateError('Torrent service is closed');
    }
    _server = server;
    server.listen(
      (request) => unawaited(_serve(request).catchError((Object _) {})),
      onError: (Object error) => KazumiLogger().w(
        'Torrent: local playback listener error',
        error: error.runtimeType.toString(),
      ),
      onDone: () {
        if (identical(_server, server)) _server = null;
      },
    );
    return true;
  }

  Future<TorrentTaskSnapshot> add(
    Uri source, {
    String? title,
    int? bangumiId,
    int? subjectId,
    double? episodeNumber,
    String? releaseKey,
    Map<String, dynamic>? subjectData,
    CancelToken? cancelToken,
  }) async {
    await initialize();
    throwIfTorrentCancelled(cancelToken);
    if (!const ['magnet', 'http', 'https'].contains(source.scheme) ||
        source.toString().length > 32768) {
      throw const FormatException('请输入磁力链接或种子文件链接');
    }
    final local = _records.values
        .where(
          (record) =>
              record.removal == null &&
              (record.snapshot.source == source ||
                  record.snapshot.id == _magnetId(source)),
        )
        .firstOrNull;
    if (local != null) {
      return _enrichSubject(local, subjectData, bangumiId ?? subjectId);
    }
    await _assertNetwork();
    if (_metadataTokens.where((token) => !token.isCancelled).length >=
        maxActiveTasks) {
      throw StateError('正在获取其它种子的资源信息，请稍后重试');
    }
    final operation = CancelToken();
    final timer = Timer(metadataTimeout, () => operation.cancel('等待种子信息超时'));
    _metadataTokens.add(operation);
    _ensureTicker();
    _emit();
    final cancellation = cancelToken?.whenCancel.asStream().listen(
      (_) => operation.cancel('已取消获取种子信息'),
    );
    String? preparedId;
    _TorrentRecord? created;
    try {
      final metadata = await _engine.resolve(source, cancelToken: operation);
      throwIfTorrentCancelled(operation);
      if (!_validId(metadata.infoHash)) {
        throw const FormatException('Invalid torrent info hash');
      }
      var existing = _records[metadata.infoHash];
      if (existing?.removal != null) {
        await existing!.removal;
        existing = _records[metadata.infoHash];
      }
      if (existing != null) {
        return await _enrichSubject(
          existing,
          subjectData,
          bangumiId ?? subjectId,
        );
      }
      preparedId = metadata.infoHash;
      _metadataWriters.update(
        preparedId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      final directory = _taskDirectory(metadata.infoHash);
      await _guardDirectory(directory);
      await File(
        p.join(directory.path, '.temporary-playback'),
      ).writeAsString('1', flush: true);
      final pendingMetadata = File(
        p.join(
          directory.path,
          '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}.torrent.part',
        ),
      );
      try {
        await pendingMetadata.writeAsBytes(metadata.bytes, flush: true);
        await pendingMetadata.rename(
          p.join(directory.path, 'metadata.torrent'),
        );
      } finally {
        if (await pendingMetadata.exists()) await pendingMetadata.delete();
      }
      throwIfTorrentCancelled(operation);
      final concurrent = _records[metadata.infoHash];
      if (concurrent != null) {
        return await _enrichSubject(
          concurrent,
          subjectData,
          bangumiId ?? subjectId,
        );
      }
      final snapshot = TorrentTaskSnapshot(
        id: metadata.infoHash,
        source: source,
        title: title?.trim().isNotEmpty == true ? title!.trim() : metadata.name,
        state: TorrentTaskState.paused,
        files: metadata.files,
        totalBytes: metadata.files.fold(0, (sum, f) => sum + f.size),
        bangumiId: bangumiId ?? subjectId,
        episodeNumber: episodeNumber,
        releaseKey: releaseKey,
        subjectData: subjectData,
      );
      created = _TorrentRecord(snapshot, metadata);
      _records[snapshot.id] = created;
      await _save();
      throwIfTorrentCancelled(operation);
      _emit();
      return snapshot;
    } catch (_) {
      if (created != null) await releaseTemporary(created.snapshot.id);
      rethrow;
    } finally {
      await cancellation?.cancel();
      timer.cancel();
      _metadataTokens.remove(operation);
      if (preparedId != null) {
        final remaining = _metadataWriters[preparedId]! - 1;
        if (remaining > 0) {
          _metadataWriters[preparedId] = remaining;
        } else {
          _metadataWriters.remove(preparedId);
          if (!_records.containsKey(preparedId)) {
            final orphan = _taskDirectory(preparedId);
            if (await orphan.exists()) {
              await _guardDirectory(orphan);
              await orphan.delete(recursive: true);
            }
          }
        }
      }
      _emit();
    }
  }

  Future<List<TorrentFileInfo>> waitForMetadata(
    String taskId, {
    CancelToken? cancelToken,
  }) async {
    await initialize();
    throwIfTorrentCancelled(cancelToken);
    return List.unmodifiable(_record(taskId).snapshot.files);
  }

  Future<TorrentTaskSnapshot> _enrichSubject(
    _TorrentRecord record,
    Map<String, dynamic>? data,
    int? requestedId,
  ) async {
    final id = (data?['id'] as num?)?.toInt();
    final boundId = record.snapshot.bangumiId ?? requestedId;
    if (data != null &&
        record.snapshot.subjectData == null &&
        id != null &&
        id == boundId) {
      record.snapshot = record.snapshot.copyWith(
        subjectData: Map.unmodifiable(data),
        bangumiId: boundId,
      );
      await _save();
      _emit();
    }
    return record.snapshot;
  }

  Future<void> startDownload(String taskId, {List<int>? fileIndices}) async {
    await initialize();
    final record = _record(taskId);
    final selection =
        fileIndices?.toSet() ??
        record.snapshot.files
            .where((f) => f.isVideo)
            .map((f) => f.index)
            .toSet();
    _validateSelection(record, selection);
    record.explicitDownload = true;
    record.downloadRequested = true;
    record.retained = true;
    record.selectedFiles = selection;
    await _save();
    await _removeTemporaryMarker(record);
    _ensureTicker();
    if (!await _networkAllowed()) {
      record.snapshot = record.snapshot.copyWith(
        state: TorrentTaskState.queued,
        notice: '等待 Wi-Fi，连接后自动继续',
        clearError: true,
      );
      await _save();
      _emit();
      return;
    }
    final TorrentEngineHandle handle;
    try {
      handle = await _activate(record);
    } on _TorrentCapacityException {
      if (!record.downloadRequested) return;
      record.snapshot = record.snapshot.copyWith(
        state: TorrentTaskState.queued,
        notice: '排队等待连接，空闲后自动继续',
        clearError: true,
      );
      await _save();
      _emit();
      return;
    }
    await handle.download(selection);
    await handle.resume();
    record.snapshot = record.snapshot.copyWith(
      state: TorrentTaskState.downloading,
      clearError: true,
      clearNotice: true,
    );
    await _save();
    _emit();
  }

  Future<void> resume(String taskId) async {
    final record = _record(taskId);
    await startDownload(
      taskId,
      fileIndices: record.selectedFiles.isEmpty
          ? null
          : record.selectedFiles.toList(),
    );
  }

  Future<void> pause(String taskId) => _pause(taskId);

  Future<void> _pause(String taskId, {bool automatic = false}) async {
    final record = _record(taskId);
    if (!automatic) record.downloadRequested = false;
    record.generation++;
    record.openToken?.cancel('Torrent task paused');
    for (final lease in record.leases.toList()) {
      await _release(lease);
    }
    await _stopHandle(record);
    record.snapshot = record.snapshot.copyWith(
      state: automatic && record.downloadRequested
          ? TorrentTaskState.queued
          : TorrentTaskState.paused,
      streamReady: false,
      downloadBytesPerSecond: 0,
      uploadBytesPerSecond: 0,
      peers: 0,
      clearNotice: !automatic,
    );
    await _save();
    _emit();
    await releaseTemporary(taskId);
    if (!automatic) _scheduleDownloads();
  }

  Future<void> cancel(String taskId) async {
    final record = _record(taskId);
    record.explicitDownload = false;
    await pause(taskId);
    if (!_records.containsKey(taskId)) return;
    record.snapshot = record.snapshot.copyWith(
      state: TorrentTaskState.cancelled,
    );
    await _save();
    _emit();
  }

  Future<void> delete(String taskId, {bool deleteFiles = true}) async {
    await pause(taskId);
    if (!_records.containsKey(taskId)) return;
    final directory = _taskDirectory(taskId);
    await _guardDirectory(directory);
    _records.remove(taskId);
    await _save();
    if (deleteFiles) await directory.delete(recursive: true);
    _emit();
  }

  /// The folder holding a task's downloaded files, when it exists.
  Future<String?> filesPath(String taskId) async {
    await initialize();
    final directory = Directory(p.join(_taskDirectory(taskId).path, 'payload'));
    return await directory.exists() ? directory.path : null;
  }

  /// Bytes under the task folders: those of tasks in the list, and leftovers
  /// nothing uses any more, such as finished playback caches and files that
  /// older versions kept after a task was deleted.
  Future<({int tasks, int unused})> storageUsage() async {
    await initialize();
    var tasks = 0, unused = 0;
    final root = Directory(p.join(_directory!.path, 'tasks'));
    if (!await root.exists()) return (tasks: 0, unused: 0);
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final size = await _directorySize(entry);
      final record = _records[p.basename(entry.path)];
      if (record != null && _inUse(record)) {
        tasks += size;
      } else {
        unused += size;
      }
    }
    return (tasks: tasks, unused: unused);
  }

  /// Deletes what [storageUsage] counts as unused.
  Future<void> clearUnused() async {
    await initialize();
    await clearInactiveCache();
    final root = Directory(p.join(_directory!.path, 'tasks'));
    if (!await root.exists()) return;
    await for (final entry in root.list(followLinks: false)) {
      final id = p.basename(entry.path);
      if (entry is! Directory ||
          !_validId(id) ||
          _records.containsKey(id) ||
          _metadataWriters.containsKey(id)) {
        continue;
      }
      await _guardDirectory(entry);
      await entry.delete(recursive: true);
    }
  }

  static bool _inUse(_TorrentRecord r) =>
      r.retained ||
      r.explicitDownload ||
      r.leases.isNotEmpty ||
      r.pendingStreams > 0;

  static Future<int> _directorySize(Directory directory) async {
    var total = 0;
    await for (final entry in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is File) total += await entry.length();
    }
    return total;
  }

  Future<void> clearInactiveCache() async {
    for (final record
        in _records.values
            .where(
              (r) => !r.retained && !r.explicitDownload && r.leases.isEmpty,
            )
            .toList()) {
      await delete(record.snapshot.id);
    }
  }

  Future<TorrentPlaybackLease> openStream(
    String taskId,
    int fileIndex, {
    CancelToken? cancelToken,
    bool downloadWhilePlaying = false,
  }) async {
    await initialize();
    final record = _record(taskId);
    record.pendingStreams++;
    String? key;
    final cancelledOpening = Completer<TorrentEngineHandle>();
    cancelledOpening.future.ignore();
    final openingCancellation = cancelToken?.whenCancel.asStream().listen((_) {
      if (!cancelledOpening.isCompleted) {
        cancelledOpening.completeError(cancelToken.cancelError!);
      }
      // Cancel initialization only when this caller owns the sole temporary
      // opening. Shared playback and retained download owners keep running.
      if (!record.explicitDownload &&
          record.leases.isEmpty &&
          record.pendingStreams == 1) {
        record.openToken?.cancel('Playback opening cancelled');
      }
    });
    try {
      throwIfTorrentCancelled(cancelToken);
      _validateSelection(record, {fileIndex});
      final file = record.snapshot.files.firstWhere(
        (f) => f.index == fileIndex,
      );
      if (!file.isVideo) throw StateError('所选文件不是可播放的视频');
      final network = await _networkAllowed();
      if (!network && file.downloadedBytes < file.size) await _assertNetwork();
      throwIfTorrentCancelled(cancelToken);
      final activation = _activate(
        record,
        allowNetwork: network,
        forPlayback: true,
      );
      final handle = cancelToken == null
          ? await activation
          : await Future.any([activation, cancelledOpening.future]);
      throwIfTorrentCancelled(cancelToken);
      key = base64Url
          .encode(List<int>.generate(24, (_) => Random.secure().nextInt(256)))
          .replaceAll('=', '');
      final state = _LeaseState(key, record, file, handle);
      _leases[key] = state;
      record.leases.add(key);
      await handle.resume();
      throwIfTorrentCancelled(cancelToken);
      if (downloadWhilePlaying) {
        final selected = {...record.selectedFiles, fileIndex};
        await handle.download(selected);
        throwIfTorrentCancelled(cancelToken);
        record.selectedFiles = selected;
        record.explicitDownload = true;
        record.downloadRequested = true;
        record.retained = true;
        await _save();
        await _removeTemporaryMarker(record);
      }
      record.snapshot = record.snapshot.copyWith(
        state: record.explicitDownload
            ? TorrentTaskState.downloading
            : TorrentTaskState.buffering,
        clearError: true,
        clearNotice: true,
      );
      _emit();
      await ensurePlaybackServer(checkConnection: true);
      throwIfTorrentCancelled(cancelToken);
      final leasePort = _server!.port;
      final lease = TorrentPlaybackLease(
        taskId: taskId,
        fileIndex: fileIndex,
        url: Uri.parse('http://127.0.0.1:$leasePort/torrent/$key'),
        currentUrl: () => Uri.parse(
          'http://127.0.0.1:${_server?.port ?? leasePort}/torrent/$key',
        ),
        close: () => _release(key!),
      );
      state.cancellation = cancelToken?.whenCancel.asStream().listen((_) {
        unawaited(lease.close());
      });
      throwIfTorrentCancelled(cancelToken);
      return lease;
    } catch (_) {
      if (key != null) await _release(key);
      throwIfTorrentCancelled(cancelToken);
      rethrow;
    } finally {
      await openingCancellation?.cancel();
      record.pendingStreams--;
      await releaseTemporary(taskId);
    }
  }

  /// Discard only a new playback cache with no current or retained owner.
  Future<void> releaseTemporary(String taskId) async {
    await initialize();
    final record = _records[taskId];
    if (record == null ||
        record.retained ||
        record.explicitDownload ||
        record.leases.isNotEmpty ||
        record.pendingStreams != 0) {
      return;
    }
    if (record.removal != null) return record.removal!;
    final removal = _removeTemporary(record);
    record.removal = removal;
    try {
      await removal;
    } finally {
      record.removal = null;
    }
  }

  Future<void> _removeTemporaryMarker(_TorrentRecord record) async {
    final marker = File(
      p.join(_taskDirectory(record.snapshot.id).path, '.temporary-playback'),
    );
    if (await marker.exists()) await marker.delete();
  }

  Future<void> _removeTemporary(_TorrentRecord record) async {
    record.generation++;
    record.openToken?.cancel('Temporary playback released');
    try {
      await record.opening;
    } catch (_) {}
    await _stopHandle(record);
    final id = record.snapshot.id;
    final directory = _taskDirectory(id);
    if (await directory.exists()) {
      await _guardDirectory(directory);
      await directory.delete(recursive: true);
    }
    _records.remove(id);
    await _save();
    _emit();
  }

  Future<TorrentEngineHandle> _activate(
    _TorrentRecord record, {
    bool allowNetwork = true,
    bool forPlayback = false,
  }) async {
    await record.stopping;
    _ensureTicker();
    if (record.handle != null) {
      if (record.networkEnabled == allowNetwork) return record.handle!;
      if (record.leases.isNotEmpty) throw StateError('请先结束当前任务的播放，再切换 BT 网络模式');
      await _stopHandle(record);
    }
    if (record.opening != null) return record.opening!;
    final generation = record.generation;
    final token = record.openToken = CancelToken();
    final completer = Completer<TorrentEngineHandle>();
    record.opening = completer.future;
    final job = _activationLane.then((_) async {
      throwIfTorrentCancelled(token);
      if (_closed) throw StateError('Torrent service is closed');
      if (allowNetwork) await _assertNetwork();
      final active = _records.values.where((r) => r.handle != null).toList();
      if (active.length >= maxActiveTasks) {
        if (!forPlayback) throw const _TorrentCapacityException();
        final idle = active
            .where((r) => r.leases.isEmpty && r.pendingStreams == 0)
            .firstOrNull;
        if (idle == null) throw StateError('已有播放任务占用 BT 引擎，请先结束其中一个播放');
        await _stopHandle(idle);
        idle.snapshot = idle.snapshot.copyWith(
          state: idle.downloadRequested
              ? TorrentTaskState.queued
              : TorrentTaskState.paused,
          streamReady: false,
          notice: idle.downloadRequested ? '为播放让出连接，播放结束后自动继续' : null,
          downloadBytesPerSecond: 0,
          uploadBytesPerSecond: 0,
          peers: 0,
        );
        if (idle.explicitDownload) {
          _notify('「${idle.snapshot.title}」正在等待播放释放连接，之后自动继续');
        }
        await _save();
        _emit();
      }
      final payload = Directory(
        p.join(_taskDirectory(record.snapshot.id).path, 'payload'),
      );
      await _guardDirectory(payload);
      final handle = await _engine.open(
        record.metadata,
        payload,
        cancelToken: token,
        allowNetwork: allowNetwork,
      );
      if (_closed || token.isCancelled || generation != record.generation) {
        await handle.close();
        throw StateError('Torrent task opening was cancelled');
      }
      record.handle = handle;
      record.networkEnabled = allowNetwork;
      if (record.explicitDownload) await handle.download(record.selectedFiles);
      completer.complete(handle);
    });
    _activationLane = job.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );
    unawaited(
      record.opening!.then<void>(
        (_) {
          record.opening = null;
          record.openToken = null;
        },
        onError: (Object _) {
          record.opening = null;
          record.openToken = null;
        },
      ),
    );
    return completer.future;
  }

  Future<void> _stopHandle(_TorrentRecord record) async {
    if (record.stopping != null) return record.stopping!;
    final handle = record.handle;
    if (handle == null) return;
    final stopping = _closeHandle(record, handle);
    record.stopping = stopping;
    try {
      await stopping;
    } finally {
      record.stopping = null;
    }
  }

  Future<void> _closeHandle(
    _TorrentRecord record,
    TorrentEngineHandle handle,
  ) async {
    try {
      final snapshot = await handle.snapshot();
      _applySnapshot(record, snapshot);
    } catch (_) {}
    record.handle = null;
    try {
      await handle.pause();
    } catch (_) {}
    await handle.close();
  }

  Future<void> _release(String key) async {
    final lease = _leases.remove(key);
    if (lease == null) return;
    await lease.cancellation?.cancel();
    lease.record.leases.remove(key);
    for (final token in lease.requests.values) {
      token.cancel('Playback stream closed');
    }
    if (!lease.record.explicitDownload &&
        lease.record.leases.isEmpty &&
        lease.record.pendingStreams == 0) {
      await _stopHandle(lease.record);
      lease.record.snapshot = lease.record.snapshot.copyWith(
        state: TorrentTaskState.paused,
        streamReady: false,
      );
    } else if (lease.record.leases.isEmpty &&
        lease.record.snapshot.state == TorrentTaskState.queued) {
      await _stopHandle(lease.record);
    } else if (lease.record.explicitDownload &&
        lease.record.snapshot.state != TorrentTaskState.completed &&
        lease.record.snapshot.state != TorrentTaskState.queued) {
      lease.record.snapshot = lease.record.snapshot.copyWith(
        state: TorrentTaskState.downloading,
      );
    }
    await _save();
    _emit();
    await releaseTemporary(lease.record.snapshot.id);
    _scheduleDownloads();
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    if (request.method == 'HEAD' &&
        request.uri.path == '/health/$_serverKey' &&
        request.headers.value('origin') == null &&
        request.headers.value(HttpHeaders.hostHeader) ==
            '127.0.0.1:${_server?.port}') {
      response.statusCode = HttpStatus.noContent;
      response.headers.set('x-monogatari-server', _serverKey);
      await response.close();
      return;
    }
    final segments = request.uri.pathSegments;
    final lease =
        segments.length == 2 &&
            segments.first == 'torrent' &&
            request.uri.query.isEmpty
        ? _leases[segments.last]
        : null;
    if (lease == null ||
        request.headers.value('origin') != null ||
        request.headers.value(HttpHeaders.hostHeader) !=
            '127.0.0.1:${_server?.port}') {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await response.close();
      return;
    }
    if (request.method == 'GET' && lease.requests.length >= 8) {
      response.statusCode = HttpStatus.serviceUnavailable;
      response.headers.set(HttpHeaders.retryAfterHeader, '1');
      await response.close();
      return;
    }
    final range = _range(
      request.headers.value(HttpHeaders.rangeHeader),
      lease.file.size,
    );
    if (range == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */${lease.file.size}',
      );
      await response.close();
      return;
    }
    response.statusCode = request.headers.value(HttpHeaders.rangeHeader) == null
        ? HttpStatus.ok
        : HttpStatus.partialContent;
    response.contentLength = range.$2 - range.$1 + 1;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set(HttpHeaders.contentTypeHeader, _mime(lease.file.name));
    if (response.statusCode == HttpStatus.partialContent) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.$1}-${range.$2}/${lease.file.size}',
      );
    }
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    final reader = '$keySeed-${_requestCounter++}';
    final token = CancelToken();
    lease.requests[reader] = token;
    unawaited(
      response.done.catchError((Object _) {
        token.cancel('Player disconnected');
      }),
    );
    try {
      var offset = range.$1;
      while (offset <= range.$2 && _leases.containsKey(lease.key)) {
        throwIfTorrentCancelled(token);
        final block = await lease.handle.read(
          reader,
          lease.file.index,
          offset,
          min(64 * 1024, range.$2 - offset + 1),
          cancelToken: token,
        );
        throwIfTorrentCancelled(token);
        if (block.isEmpty) {
          throw const FileSystemException('Empty torrent piece');
        }
        response.add(block);
        await response.flush();
        offset += block.length;
        lease.record.snapshot = lease.record.snapshot.copyWith(
          streamReady: true,
          state: lease.record.explicitDownload
              ? TorrentTaskState.downloading
              : TorrentTaskState.buffering,
        );
      }
    } catch (error) {
      if (!token.isCancelled && _leases.containsKey(lease.key)) {
        lease.record.snapshot = lease.record.snapshot.copyWith(
          error: error.toString(),
        );
        _emit();
      }
    } finally {
      lease.requests.remove(reader);
      try {
        await lease.handle.removeReader(reader);
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
    }
  }

  static final keySeed = base64Url.encode(
    List.generate(12, (_) => Random.secure().nextInt(256)),
  );
  int _requestCounter = 0;

  // Ticks only while a task is resolving or running, so an idle app sleeps.
  void _ensureTicker() {
    if (_closed || _timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _refreshWork ??= _refresh().whenComplete(() => _refreshWork = null);
    });
  }

  bool get _hasWork =>
      _metadataTokens.any((token) => !token.isCancelled) ||
      _records.values.any(
        (r) =>
            r.handle != null ||
            r.opening != null ||
            (r.downloadRequested &&
                r.snapshot.state == TorrentTaskState.queued),
      );

  void _scheduleDownloads() {
    if (_closed || _drainingDownloads || _drainWork != null) return;
    _drainWork = _drainDownloads().whenComplete(() => _drainWork = null);
  }

  Future<void> _drainDownloads() async {
    if (_closed || _drainingDownloads) return;
    _drainingDownloads = true;
    try {
      if (!await _networkAllowed()) return;
      for (final record in _records.values.toList()) {
        if (_closed) return;
        if (!record.downloadRequested ||
            record.snapshot.state != TorrentTaskState.queued ||
            record.handle != null ||
            record.opening != null)
          continue;
        if (_records.values
                .where((r) => r.handle != null || r.opening != null)
                .length >=
            maxActiveTasks)
          break;
        try {
          await startDownload(
            record.snapshot.id,
            fileIndices: record.selectedFiles.toList(),
          );
        } catch (error) {
          if (_closed) return;
          if (!record.downloadRequested) continue;
          record.downloadRequested = false;
          record.snapshot = record.snapshot.copyWith(
            state: TorrentTaskState.error,
            error: error.toString(),
          );
          await _save();
          _emit();
        }
      }
    } finally {
      _drainingDownloads = false;
    }
  }

  /// Also callable when network/settings observers report a policy change.
  Future<void> refreshNetworkPolicy() async {
    if (_closed) return;
    if (await _networkAllowed()) {
      await _drainDownloads();
      return;
    }
    for (final token in _metadataTokens.toList()) {
      token.cancel('当前网络不允许 BT 下载');
    }
    final stopped = _records.values
        .where(
          (r) => r.networkEnabled && (r.handle != null || r.opening != null),
        )
        .toList();
    for (final record in stopped) {
      await _pause(record.snapshot.id, automatic: true);
      if (_records.containsKey(record.snapshot.id)) {
        record.snapshot = record.snapshot.copyWith(
          notice: record.downloadRequested
              ? '等待 Wi-Fi，连接后自动继续'
              : '当前不是 Wi-Fi，请连接后重新播放',
        );
      }
    }
    if (stopped.isNotEmpty) {
      _notify('当前不是 Wi-Fi，磁力下载等待网络恢复后自动继续');
      await _save();
      _emit();
    }
  }

  void _notify(String message) {
    if (!_noticeController.isClosed) _noticeController.add(message);
  }

  Future<void> _refresh() async {
    if (_closed || _refreshing) return;
    if (!_hasWork) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _refreshing = true;
    try {
      if (DateTime.now().difference(_lastPolicyCheck) >=
          const Duration(seconds: 5)) {
        _lastPolicyCheck = DateTime.now();
        await refreshNetworkPolicy();
      }
      for (final record
          in _records.values.where((r) => r.handle != null).toList()) {
        try {
          final data = await record.handle!.snapshot();
          _applySnapshot(record, data);
          if (record.explicitDownload && record.snapshot.progress >= 1) {
            record.downloadRequested = false;
            record.snapshot = record.snapshot.copyWith(
              state: TorrentTaskState.completed,
            );
            if (record.leases.isEmpty) await _stopHandle(record);
            await _save();
          }
        } catch (error) {
          try {
            await _stopHandle(record);
          } catch (_) {}
          record.snapshot = record.snapshot.copyWith(
            state: TorrentTaskState.error,
            error: error.toString(),
          );
          record.downloadRequested = false;
        }
      }
      await _drainDownloads();
      _emit();
    } finally {
      _refreshing = false;
    }
  }

  void _applySnapshot(_TorrentRecord record, TorrentEngineSnapshot data) {
    final chosen = record.selectedFiles.isNotEmpty
        ? record.selectedFiles
        : record.leases
              .map((id) => _leases[id]?.file.index)
              .whereType<int>()
              .toSet();
    final files = chosen.isEmpty
        ? data.files
        : data.files.where((f) => chosen.contains(f.index));
    final total = files.fold(0, (sum, f) => sum + f.size);
    final downloaded = files.fold(0, (sum, f) => sum + f.downloadedBytes);
    record.snapshot = record.snapshot.copyWith(
      files: data.files,
      progress: total > 0 ? (downloaded / total).clamp(0.0, 1.0) : 0,
      downloadedBytes: downloaded,
      totalBytes: total,
      downloadBytesPerSecond: data.downloadBytesPerSecond,
      uploadBytesPerSecond: data.uploadBytesPerSecond,
      peers: data.peers,
    );
  }

  _TorrentRecord _record(String id) {
    final record = _records[id];
    if (record == null || record.removal != null) throw StateError('种子任务不存在');
    return record;
  }

  Directory _taskDirectory(String id) {
    if (!_validId(id)) throw const FormatException('Invalid torrent task ID');
    return Directory(p.join(_directory!.path, 'tasks', id));
  }

  static bool _validId(String id) => RegExp(r'^[a-f0-9]{40}$').hasMatch(id);
  void _validateSelection(_TorrentRecord record, Set<int> indices) {
    if (indices.isEmpty ||
        indices.any(
          (index) =>
              index < 0 ||
              index >= record.snapshot.files.length ||
              record.snapshot.files[index].size <= 0,
        )) {
      throw RangeError('Invalid torrent file selection');
    }
  }

  Future<void> _save() {
    final next = _saveLane.then((_) async {
      if (_directory == null) return;
      final pending = File(p.join(_directory!.path, 'tasks.json.part'));
      await pending.writeAsString(
        jsonEncode(
          _records.values
              .map(
                (r) => {
                  'snapshot': r.snapshot.toJson(),
                  'pieceLength': r.metadata.pieceLength,
                  'explicitDownload': r.explicitDownload,
                  'downloadRequested': r.downloadRequested,
                  'retained': r.retained,
                  'selectedFiles': r.selectedFiles.toList(),
                },
              )
              .toList(),
        ),
        flush: true,
      );
      await pending.rename(p.join(_directory!.path, 'tasks.json'));
    });
    _saveLane = next.catchError((Object _) {});
    return next;
  }

  void _emit() {
    if (!_tasksController.isClosed) _tasksController.add(tasks);
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    for (final token in _metadataTokens.toList()) {
      token.cancel('Torrent service closed');
    }
    for (final record in _records.values) {
      record.openToken?.cancel('Torrent service closed');
    }
    await _drainWork;
    await _refreshWork;
    try {
      await _serverRepair;
    } catch (_) {
      // Disposal can invalidate a listener that is still being rebound.
    }
    for (final key in _leases.keys.toList()) {
      await _release(key);
    }
    await _activationLane;
    for (final record in _records.values.toList()) {
      await _stopHandle(record);
      await releaseTemporary(record.snapshot.id);
    }
    await _save();
    await _server?.close(force: true);
    await _engine.dispose();
    await _tasksController.close();
    await _capabilityController.close();
    await _noticeController.close();
  }
}

class _TorrentRecord {
  TorrentTaskSnapshot snapshot;
  final TorrentMetadata metadata;
  bool explicitDownload;
  bool downloadRequested;
  bool retained;
  Set<int> selectedFiles;
  TorrentEngineHandle? handle;
  Future<TorrentEngineHandle>? opening;
  Future<void>? stopping;
  CancelToken? openToken;
  final Set<String> leases = {};
  int generation = 0;
  bool networkEnabled = true;
  int pendingStreams = 0;
  Future<void>? removal;
  _TorrentRecord(
    this.snapshot,
    this.metadata, {
    this.explicitDownload = false,
    this.downloadRequested = false,
    this.retained = false,
    Set<int>? selectedFiles,
  }) : selectedFiles = selectedFiles ?? {};
}

class _TorrentCapacityException implements Exception {
  const _TorrentCapacityException();
}

class _LeaseState {
  final String key;
  final _TorrentRecord record;
  final TorrentFileInfo file;
  final TorrentEngineHandle handle;
  final requests = <String, CancelToken>{};
  StreamSubscription<DioException>? cancellation;
  _LeaseState(this.key, this.record, this.file, this.handle);
}

(int, int)? _range(String? header, int size) {
  if (size <= 0) return null;
  if (header == null) return (0, size - 1);
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) return null;
  if (match[1]!.isEmpty) {
    final suffix = int.tryParse(match[2]!);
    if (suffix == null || suffix <= 0) return null;
    return (max(0, size - suffix), size - 1);
  }
  final start = int.tryParse(match[1]!);
  final end = match[2]!.isEmpty ? size - 1 : int.tryParse(match[2]!);
  if (start == null || end == null || start >= size || end < start) return null;
  return (start, min(end, size - 1));
}

String _mime(String file) => switch (p.extension(file).toLowerCase()) {
  '.mp4' || '.m4v' => 'video/mp4',
  '.mkv' => 'video/x-matroska',
  '.webm' => 'video/webm',
  '.mov' => 'video/quicktime',
  '.ts' => 'video/mp2t',
  '.avi' => 'video/x-msvideo',
  _ => 'application/octet-stream',
};

String? _magnetId(Uri uri) {
  if (uri.scheme != 'magnet') return null;
  for (final value in uri.queryParametersAll['xt'] ?? <String>[]) {
    const prefix = 'urn:btih:';
    if (!value.toLowerCase().startsWith(prefix)) continue;
    final hash = value.substring(prefix.length);
    if (RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(hash)) return hash.toLowerCase();
    if (!RegExp(r'^[A-Z2-7]{32}$', caseSensitive: false).hasMatch(hash)) {
      continue;
    }
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    var buffer = 0, bits = 0;
    final bytes = <int>[];
    for (final char in hash.toUpperCase().split('')) {
      buffer = (buffer << 5) | alphabet.indexOf(char);
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        bytes.add((buffer >> bits) & 255);
        buffer &= (1 << bits) - 1;
      }
    }
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
  return null;
}

Future<void> _guardDirectory(Directory directory) async {
  var cursor = p.normalize(p.absolute(directory.path));
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
    if (entry is Link) {
      throw const FileSystemException(
        'Torrent storage contains a symbolic link',
      );
    }
  }
}
