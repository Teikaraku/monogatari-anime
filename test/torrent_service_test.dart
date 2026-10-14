import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/torrent/torrent_engine.dart';
import 'package:kazumi/services/torrent/torrent_models.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';

void main() {
  late Directory directory;
  late _Engine engine;
  late TorrentService service;
  late HttpClient client;
  var allowed = true;
  final source = Uri.parse('https://fixture.invalid/movie.torrent');

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'monogatari-torrent-service-',
    );
    engine = _Engine();
    allowed = true;
    service = TorrentService(
      engine: engine,
      directoryProvider: () async => directory,
      networkAllowed: () async => allowed,
    );
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await service.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'rebinds a closed playback port without losing the active torrent lease',
    () async {
      await service.dispose();
      final servers = <HttpServer>[];
      service = TorrentService(
        engine: engine,
        directoryProvider: () async => directory,
        serverBinder: () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          servers.add(server);
          return server;
        },
      );
      final task = await service.add(source);
      final lease = await service.openStream(task.id, 0);
      final oldUrl = lease.url;
      final handle = engine.handles.single;
      expect(
        await service.ensurePlaybackServer(checkConnection: true),
        isFalse,
      );
      engine.blockReads = true;
      final blocked = client
          .getUrl(lease.url)
          .then((request) => request.close())
          .then((response) => response.drain<void>());
      final cancelled = expectLater(blocked, throwsA(isA<Exception>()));
      await engine.readStarted.future;
      await servers.single.close(force: true);
      await Future<void>.delayed(Duration.zero);
      expect(await service.ensurePlaybackServer(checkConnection: true), isTrue);
      await cancelled.timeout(const Duration(seconds: 1));
      expect(engine.readCancelled, isTrue);
      engine.blockReads = false;
      expect(servers, hasLength(2));
      expect(lease.url.path, oldUrl.path);
      expect(lease.url.port, servers.last.port);
      expect(handle.closed, isFalse);
      final response = await (await client.getUrl(lease.url)).close();
      expect(response.statusCode, HttpStatus.ok);
      expect(
        await response.fold<List<int>>(
          [],
          (bytes, block) => bytes..addAll(block),
        ),
        engine.data,
      );
      expect(engine.handles, hasLength(1));
      client.findProxy = (_) => 'PROXY 127.0.0.1:${lease.url.port}';
      final proxied = await (await client.getUrl(lease.url)).close();
      expect(proxied.statusCode, HttpStatus.ok);
      expect(
        await proxied.fold<List<int>>([], (out, bytes) => out..addAll(bytes)),
        engine.data,
      );
      await lease.close();
    },
  );

  test(
    'loopback responds with correct head, suffix, seek and 416 ranges',
    () async {
      final task = await service.add(source);
      final lease = await service.openStream(task.id, 0);
      final head = await (await client.openUrl('HEAD', lease.url)).close();
      expect(head.statusCode, HttpStatus.ok);
      expect(head.contentLength, 64);
      expect(
        await head.fold<List<int>>([], (bytes, block) => bytes..addAll(block)),
        isEmpty,
      );
      Future<(HttpClientResponse, List<int>)> get(String range) async {
        final request = await client.getUrl(lease.url);
        request.headers.set(HttpHeaders.rangeHeader, range);
        final response = await request.close();
        final bytes = await response.fold<List<int>>(
          [],
          (bytes, block) => bytes..addAll(block),
        );
        return (response, bytes);
      }

      final seek = await get('bytes=32-39');
      expect(seek.$1.statusCode, HttpStatus.partialContent);
      expect(
        seek.$1.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 32-39/64',
      );
      expect(seek.$2, engine.data.sublist(32, 40));
      final tail = await get('bytes=-4');
      expect(tail.$2, engine.data.sublist(60));
      for (final invalid in [
        'bytes=64-',
        'bytes=4-3',
        'bytes=0-1,4-5',
        'bytes=-0',
      ]) {
        final response = await get(invalid);
        expect(response.$1.statusCode, HttpStatus.requestedRangeNotSatisfiable);
        expect(
          response.$1.headers.value(HttpHeaders.contentRangeHeader),
          'bytes */64',
        );
        expect(response.$2, isEmpty);
      }
      final wrongPath = await (await client.getUrl(
        lease.url.replace(path: '/torrent/unknown'),
      )).close();
      expect(wrongPath.statusCode, HttpStatus.notFound);
      await wrongPath.drain<void>();
      await lease.close();
      expect(engine.handles.single.closed, isTrue);
      expect(engine.selections, isEmpty);
      expect(service.tasks, isEmpty);
      expect(
        await Directory('${directory.path}/tasks/${task.id}').exists(),
        isFalse,
      );
    },
  );

  test(
    'closing the last playback lease cancels a blocked piece read promptly',
    () async {
      engine.blockReads = true;
      final task = await service.add(source);
      final lease = await service.openStream(task.id, 0);
      final request = await client.getUrl(lease.url);
      final responseFuture = request.close();
      final result = responseFuture.then((response) => response.drain<void>());
      final assertion = expectLater(result, throwsA(isA<Exception>()));
      await engine.readStarted.future;
      await lease.close().timeout(const Duration(seconds: 1));
      await assertion;
      expect(engine.readCancelled, isTrue);
      expect(engine.handles.single.closed, isTrue);
      expect(service.tasks, isEmpty);
    },
  );

  test(
    'a download owner survives playback closure and is excluded from cache cleanup',
    () async {
      final task = await service.add(source);
      await service.startDownload(task.id, fileIndices: [0]);
      final lease = await service.openStream(task.id, 0);
      await lease.close();
      expect(engine.handles.single.closed, isFalse);
      expect(service.tasks.single.state, TorrentTaskState.downloading);
      await service.pause(task.id);
      await service.clearInactiveCache();
      expect(service.tasks.single.id, task.id);
    },
  );

  test(
    'cached source and magnet reuse work offline and use a network-free reader',
    () async {
      final task = await service.add(source);
      final lease = await service.openStream(
        task.id,
        0,
        downloadWhilePlaying: true,
      );
      await lease.close();
      await service.pause(task.id);
      allowed = false;
      expect((await service.add(source)).id, task.id);
      expect(
        (await service.add(Uri.parse('magnet:?xt=urn:btih:${task.id}'))).id,
        task.id,
      );
      expect(engine.resolutions, 1);
      final cached = await service.openStream(task.id, 0);
      expect(engine.networkModes.last, isFalse);
      final response = await (await client.getUrl(cached.url)).close();
      expect(
        await response.fold<List<int>>(
          [],
          (bytes, block) => bytes..addAll(block),
        ),
        engine.data,
      );
      await cached.close();
      await service.resume(task.id);
      expect(service.tasks.single.state, TorrentTaskState.queued);
    },
  );

  test(
    'initialization can recover after the directory provider is repaired',
    () async {
      await service.dispose();
      var fail = true;
      service = TorrentService(
        engine: engine,
        directoryProvider: () async {
          if (fail) {
            throw const FileSystemException('temporary storage failure');
          }
          return directory;
        },
      );
      await expectLater(
        service.initialize(),
        throwsA(isA<FileSystemException>()),
      );
      expect(service.capability.ready, isFalse);
      fail = false;
      await service.initialize();
      expect(service.capability.ready, isTrue);
    },
  );

  test(
    'restored download tasks retain identity and automatically continue',
    () async {
      final task = await service.add(
        source,
        bangumiId: 123,
        episodeNumber: 2,
        releaseKey: 'release-2',
      );
      await service.startDownload(task.id, fileIndices: [0]);
      await service.dispose();
      engine = _Engine();
      service = TorrentService(
        engine: engine,
        directoryProvider: () async => directory,
      );
      await service.initialize();
      final restored = service.tasks.single;
      expect(restored.id, task.id);
      expect(restored.state, TorrentTaskState.queued);
      expect(restored.bangumiId, 123);
      expect(restored.releaseKey, 'release-2');
      expect(restored.episodeNumber, 2);
      for (var i = 0; i < 100 && engine.handles.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.handles, isNotEmpty);
      await service.clearInactiveCache();
      expect(service.tasks, hasLength(1));
    },
  );

  test(
    'temporary playback survives another lease and is removed after the last one',
    () async {
      final task = await service.add(source);
      final first = await service.openStream(task.id, 0);
      final second = await service.openStream(task.id, 0);
      await first.close();
      expect(service.tasks.single.id, task.id);
      expect(engine.handles.single.closed, isFalse);
      expect(engine.selections, isEmpty);
      await second.close();
      expect(service.tasks, isEmpty);
      expect(engine.handles.single.closed, isTrue);
      expect(
        await Directory('${directory.path}/tasks/${task.id}').exists(),
        isFalse,
      );
    },
  );

  test(
    'concurrent lease closure waits for owned file IO before deleting temporary data',
    () async {
      engine.blockClose = true;
      final task = await service.add(source);
      final first = await service.openStream(task.id, 0);
      final second = await service.openStream(task.id, 0);
      final closes = Future.wait([first.close(), second.close()]);
      await engine.closeStarted.future;
      expect(
        await Directory('${directory.path}/tasks/${task.id}').exists(),
        isTrue,
      );
      expect(service.tasks, hasLength(1));
      engine.closeGate.complete();
      await closes.timeout(const Duration(seconds: 1));
      expect(service.tasks, isEmpty);
      expect(
        await Directory('${directory.path}/tasks/${task.id}').exists(),
        isFalse,
      );
      expect(engine.handles.single.closeCalls, 1);
    },
  );

  test(
    'retained playback merges selected files and cancellation cannot erase the saved download',
    () async {
      engine.batch = true;
      final task = await service.add(source);
      await service.startDownload(task.id, fileIndices: [0]);
      final lease = await service.openStream(
        task.id,
        1,
        downloadWhilePlaying: true,
      );
      expect(engine.selections.last, {0, 1});
      await lease.close();
      expect(engine.handles.single.closed, isFalse);
      await service.cancel(task.id);
      await service.releaseTemporary(task.id);
      await service.clearInactiveCache();
      expect(service.tasks.single.state, TorrentTaskState.cancelled);
      expect(
        await File(
          '${directory.path}/tasks/${task.id}/payload/video.mp4',
        ).exists(),
        isTrue,
      );
    },
  );

  test(
    'retained playback starts only its selected file and continues after the player closes',
    () async {
      engine.batch = true;
      final task = await service.add(source);
      final lease = await service.openStream(
        task.id,
        1,
        downloadWhilePlaying: true,
      );
      expect(engine.selections, [
        {1},
      ]);
      await lease.close();
      expect(engine.handles.single.closed, isFalse);
      expect(service.tasks.single.state, TorrentTaskState.downloading);
      final rows =
          jsonDecode(await File('${directory.path}/tasks.json').readAsString())
              as List;
      expect(rows.single['retained'], isTrue);
      expect(rows.single['selectedFiles'], [1]);
      expect(
        await File(
          '${directory.path}/tasks/${task.id}/.temporary-playback',
        ).exists(),
        isFalse,
      );
    },
  );

  for (final failResume in [false, true]) {
    test(
      'failed ${failResume ? 'resume' : 'initialization'} removes partial temporary payload',
      () async {
        engine.failOpen = !failResume;
        engine.failResume = failResume;
        final task = await service.add(source);
        await expectLater(service.openStream(task.id, 0), throwsStateError);
        expect(service.tasks, isEmpty);
        expect(
          await Directory('${directory.path}/tasks/${task.id}').exists(),
          isFalse,
        );
        if (failResume) expect(engine.handles.single.closed, isTrue);
      },
    );
  }

  test(
    'cancelled temporary opening waits for engine cleanup and removes its files',
    () async {
      engine.blockOpen = true;
      final task = await service.add(source);
      final token = CancelToken();
      final opening = service.openStream(task.id, 0, cancelToken: token);
      final assertion = expectLater(opening, throwsA(isA<DioException>()));
      await engine.openStarted.future;
      token.cancel('leave player');
      await assertion.timeout(const Duration(seconds: 1));
      expect(service.tasks, isEmpty);
      expect(
        await Directory('${directory.path}/tasks/${task.id}').exists(),
        isFalse,
      );
    },
  );

  test(
    'cancelling one opening does not interrupt a second lease sharing initialization',
    () async {
      engine.blockOpen = true;
      final task = await service.add(source);
      final token = CancelToken();
      final first = service.openStream(task.id, 0, cancelToken: token);
      final assertion = expectLater(first, throwsA(isA<DioException>()));
      await engine.openStarted.future;
      final second = service.openStream(task.id, 0);
      // Let the second caller register its pending ownership before cancellation.
      await Future<void>.delayed(Duration.zero);
      token.cancel('close first player');
      await assertion.timeout(const Duration(seconds: 1));
      expect(service.tasks.single.id, task.id);
      engine.openGate.complete();
      final lease = await second.timeout(const Duration(seconds: 1));
      expect(engine.handles.single.closed, isFalse);
      await lease.close();
      expect(service.tasks, isEmpty);
    },
  );

  test(
    'restart deletes temporary playback and interrupted metadata, preserving retained and legacy files',
    () async {
      final temporary = await service.add(source);
      engine.infoHash = '1123456789012345678901234567890123456789';
      final retained = await service.add(
        source.replace(path: '/saved.torrent'),
      );
      await service.startDownload(retained.id, fileIndices: [0]);
      final manifest = await File(
        '${directory.path}/tasks.json',
      ).readAsString();
      await service.dispose();
      // Recreate the disk state of a process terminated before lease cleanup.
      await File('${directory.path}/tasks.json').writeAsString(manifest);
      Future<void> createStale(String id, {required bool marked}) async {
        final folder = Directory('${directory.path}/tasks/$id');
        await folder.create(recursive: true);
        await File('${folder.path}/metadata.torrent').writeAsBytes(engine.data);
        if (marked) {
          await File('${folder.path}/.temporary-playback').writeAsString('1');
        }
      }

      await createStale(temporary.id, marked: true);
      const orphan = '2123456789012345678901234567890123456789';
      const unknownLegacy = '3123456789012345678901234567890123456789';
      await createStale(orphan, marked: true);
      await createStale(unknownLegacy, marked: false);
      engine = _Engine();
      service = TorrentService(
        engine: engine,
        directoryProvider: () async => directory,
      );
      await service.initialize();
      expect(service.tasks.single.id, retained.id);
      expect(
        await Directory('${directory.path}/tasks/${temporary.id}').exists(),
        isFalse,
      );
      expect(
        await Directory('${directory.path}/tasks/$orphan').exists(),
        isFalse,
      );
      expect(
        await Directory('${directory.path}/tasks/$unknownLegacy').exists(),
        isTrue,
      );
      expect(
        await File(
          '${directory.path}/tasks/${retained.id}/payload/video.mp4',
        ).exists(),
        isTrue,
      );
    },
  );

  test(
    'old manifests without retention flags are preserved even after download cancellation',
    () async {
      final task = await service.add(source);
      await service.startDownload(task.id, fileIndices: [0]);
      await service.cancel(task.id);
      await service.dispose();
      final manifest = File('${directory.path}/tasks.json');
      final rows = jsonDecode(await manifest.readAsString()) as List;
      (rows.single as Map).remove('retained');
      await manifest.writeAsString(jsonEncode(rows));
      engine = _Engine();
      service = TorrentService(
        engine: engine,
        directoryProvider: () async => directory,
      );
      await service.initialize();
      await service.releaseTemporary(task.id);
      await service.clearInactiveCache();
      expect(service.tasks.single.id, task.id);
      expect(
        await File(
          '${directory.path}/tasks/${task.id}/payload/video.mp4',
        ).exists(),
        isTrue,
      );
    },
  );

  test(
    'foreground playback evicts idle background work within the active-task limit without deleting its data',
    () async {
      final first = await service.add(source);
      await service.startDownload(first.id, fileIndices: [0]);
      engine.infoHash = '1123456789012345678901234567890123456789';
      final second = await service.add(source.replace(path: '/second.torrent'));
      await service.startDownload(second.id, fileIndices: [0]);
      engine.infoHash = '2123456789012345678901234567890123456789';
      final third = await service.add(source.replace(path: '/third.torrent'));
      final lease = await service.openStream(third.id, 0);
      expect(engine.handles.where((handle) => !handle.closed), hasLength(2));
      expect(
        service.tasks.firstWhere((task) => task.id == first.id).state,
        TorrentTaskState.queued,
      );
      expect(
        await File(
          '${directory.path}/tasks/${first.id}/payload/video.mp4',
        ).exists(),
        isTrue,
      );
      await lease.close();
      expect(service.tasks.map((task) => task.id), [first.id, second.id]);
    },
  );

  Future<TorrentTaskSnapshot> addTask(int number) async {
    engine.infoHash = '$number'.padLeft(40, '0');
    return service.add(source.replace(path: '/$number.torrent'));
  }

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 100 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  test('a third download queues without interrupting the first two', () async {
    engine.downloadedBytes = 0;
    final tasks = [await addTask(1), await addTask(2), await addTask(3)];
    for (final task in tasks) {
      await service.startDownload(task.id);
    }
    expect(service.tasks.map((task) => task.state), [
      TorrentTaskState.downloading,
      TorrentTaskState.downloading,
      TorrentTaskState.queued,
    ]);
    expect(engine.handles.where((handle) => !handle.closed), hasLength(2));
    await service.pause(tasks.first.id);
    await waitFor(
      () => service.tasks.last.state == TorrentTaskState.downloading,
    );
    expect(service.tasks.first.state, TorrentTaskState.paused);
    expect(engine.handles.where((handle) => !handle.closed), hasLength(2));
  });

  test(
    'playback announces preemption and restores the waiting download',
    () async {
      engine.downloadedBytes = 0;
      final first = await addTask(1),
          second = await addTask(2),
          third = await addTask(3);
      await service.startDownload(first.id);
      await service.startDownload(second.id);
      final notice = service.notices.first;
      final lease = await service.openStream(third.id, 0);
      expect(await notice, contains('自动继续'));
      expect(service.tasks.first.state, TorrentTaskState.queued);
      await lease.close();
      await waitFor(
        () => service.tasks.first.state == TorrentTaskState.downloading,
      );
      expect(
        service.tasks.map((task) => task.state),
        everyElement(TorrentTaskState.downloading),
      );
    },
  );

  test(
    'Wi-Fi restoration resumes automatic waits but not manual pauses',
    () async {
      engine.downloadedBytes = 0;
      final first = await addTask(1), second = await addTask(2);
      await service.startDownload(first.id);
      await service.startDownload(second.id);
      allowed = false;
      await service.refreshNetworkPolicy();
      expect(
        service.tasks.map((task) => task.state),
        everyElement(TorrentTaskState.queued),
      );
      expect(engine.handles.where((handle) => !handle.closed), isEmpty);
      await service.pause(second.id);
      allowed = true;
      await service.refreshNetworkPolicy();
      expect(service.tasks.first.state, TorrentTaskState.downloading);
      expect(service.tasks.last.state, TorrentTaskState.paused);
    },
  );

  test('pausing all queued work cancels its automatic continuation', () async {
    engine.downloadedBytes = 0;
    final tasks = [await addTask(1), await addTask(2), await addTask(3)];
    for (final task in tasks) {
      await service.startDownload(task.id);
    }
    for (final task in tasks.reversed) {
      await service.pause(task.id);
    }
    await service.refreshNetworkPolicy();
    expect(
      service.tasks.map((task) => task.state),
      everyElement(TorrentTaskState.paused),
    );
    expect(engine.handles.where((handle) => !handle.closed), isEmpty);
  });
}

class _Engine implements TorrentEngine {
  final data = Uint8List.fromList(List.generate(64, (index) => index));
  final handles = <_Handle>[];
  final networkModes = <bool>[];
  final readStarted = Completer<void>();
  final openStarted = Completer<void>();
  final openGate = Completer<void>();
  final closeStarted = Completer<void>();
  final closeGate = Completer<void>();
  final selections = <Set<int>>[];
  bool blockReads = false;
  bool blockOpen = false;
  bool blockClose = false;
  bool failOpen = false;
  bool failResume = false;
  bool batch = false;
  int downloadedBytes = 64;
  String infoHash = '0123456789012345678901234567890123456789';
  bool readCancelled = false;
  int resolutions = 0;
  List<TorrentFileInfo> get files => [
    TorrentFileInfo(
      index: 0,
      name: 'video.mp4',
      size: 64,
      downloadedBytes: downloadedBytes,
      isVideo: true,
    ),
    if (batch)
      const TorrentFileInfo(
        index: 1,
        name: 'second.mp4',
        size: 64,
        downloadedBytes: 64,
        isVideo: true,
      ),
  ];
  @override
  Future<TorrentMetadata> resolve(
    Uri source, {
    CancelToken? cancelToken,
  }) async {
    resolutions++;
    return TorrentMetadata(
      infoHash: infoHash,
      name: 'video.mp4',
      bytes: data,
      files: files,
      pieceLength: 16,
    );
  }

  @override
  Future<TorrentEngineHandle> open(
    TorrentMetadata metadata,
    Directory directory, {
    CancelToken? cancelToken,
    bool allowNetwork = true,
  }) async {
    networkModes.add(allowNetwork);
    await File('${directory.path}/video.mp4').writeAsBytes(data, flush: true);
    if (!openStarted.isCompleted) openStarted.complete();
    if (failOpen) throw StateError('engine initialization failed');
    if (blockOpen) {
      await Future.any([
        openGate.future,
        cancelToken!.whenCancel.then((error) => throw error),
      ]);
    }
    final handle = _Handle(this);
    handles.add(handle);
    return handle;
  }

  @override
  Future<void> dispose() async {}
}

class _Handle implements TorrentEngineHandle {
  final _Engine engine;
  bool closed = false;
  int closeCalls = 0;
  _Handle(this.engine);
  @override
  Future<TorrentEngineSnapshot> snapshot() async =>
      TorrentEngineSnapshot(files: engine.files);
  @override
  Future<void> download(Set<int> fileIndices) async {
    engine.selections.add(Set.of(fileIndices));
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {
    if (engine.failResume) throw StateError('engine resume failed');
  }

  @override
  Future<void> setReader(
    String readerId,
    int fileIndex,
    int byteOffset,
  ) async {}
  @override
  Future<void> removeReader(String readerId) async {}
  @override
  Future<Uint8List> read(
    String readerId,
    int fileIndex,
    int byteOffset,
    int length, {
    CancelToken? cancelToken,
  }) async {
    if (!engine.readStarted.isCompleted) engine.readStarted.complete();
    if (engine.blockReads) {
      await cancelToken!.whenCancel;
      engine.readCancelled = true;
      throw cancelToken.cancelError!;
    }
    return engine.data.sublist(byteOffset, byteOffset + length);
  }

  @override
  Future<void> close() async {
    closeCalls++;
    if (!engine.closeStarted.isCompleted) engine.closeStarted.complete();
    if (engine.blockClose) await engine.closeGate.future;
    closed = true;
  }
}
