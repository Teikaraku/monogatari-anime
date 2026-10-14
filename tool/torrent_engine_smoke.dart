import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dtorrent_task_v2/dtorrent_task_v2.dart' as bt;

import 'package:kazumi/services/torrent/dart_torrent_engine.dart';
import '../test/support/torrent_loopback_fixture.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  const pieceLength = 1024 * 1024;
  final fixture = TorrentLoopbackFixture(
    pieceLength: pieceLength,
    data: Uint8List.fromList(
      List.generate(
        40 * pieceLength,
        (index) => (index * 31 + index ~/ pieceLength) & 255,
      ),
    ),
  );
  final directory = await Directory.systemTemp.createTemp(
    'monogatari-bt-engine-',
  );
  final engine = DartTorrentEngine(allowLoopbackPeers: true);
  Timer? diagnosis;
  await fixture.start();
  try {
    final metadataClock = Stopwatch()..start();
    final metadata = await engine
        .resolve(fixture.source)
        .timeout(const Duration(seconds: 15));
    metadataClock.stop();
    check(
      metadata.infoHash ==
          fixture.infoHash
              .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
              .join(),
      'binary info dictionary preserves exact swarm hash',
    );
    check(
      metadata.files.length == 1 &&
          metadata.files.first.size == fixture.data.length,
      'real torrent metadata',
    );
    final initializeClock = Stopwatch()..start();
    final handle = await engine
        .open(metadata, directory)
        .timeout(const Duration(seconds: 20));
    initializeClock.stop();
    check(
      fixture.requests.isEmpty,
      'initialization requests no unselected payload',
    );
    diagnosis = Timer.periodic(const Duration(seconds: 2), (_) async {
      final state = await handle.snapshot();
      stdout.writeln(
        'fixture peers=${state.peers}, requests=${fixture.requests.length}, bytes=${state.files.first.downloadedBytes}',
      );
    });
    final firstPieceClock = Stopwatch()..start();
    final first = await handle
        .read('playback', 0, 0, 4096)
        .timeout(const Duration(seconds: 20));
    firstPieceClock.stop();
    diagnosis.cancel();
    check(
      first.toString() == fixture.data.sublist(0, 4096).toString(),
      'first piece checksum and bytes',
    );
    check(
      fixture.requests.every((piece) => piece >= 0 && piece < 16),
      'stream-only requests the current piece and its bounded forward window',
    );
    final tailOffset = fixture.data.length - 4096;
    final seekClock = Stopwatch()..start();
    final tail = await handle
        .read('playback', 0, tailOffset, 4096)
        .timeout(const Duration(seconds: 20));
    seekClock.stop();
    check(
      tail.toString() == fixture.data.sublist(tailOffset).toString(),
      'tail Range seek bytes',
    );
    check(
      fixture.requests.every((piece) => piece < 16 || piece == 39),
      'seek moves directly to the tail without downloading intervening pieces',
    );
    await handle.removeReader('playback');
    fixture.withheld.add(20);
    final cancelled = CancelToken();
    final read = handle.read(
      'cancelled',
      0,
      20 * pieceLength,
      4096,
      cancelToken: cancelled,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    cancelled.cancel('fixture cancel');
    try {
      await read.timeout(const Duration(seconds: 2));
      throw StateError('blocked read was not cancelled');
    } on DioException catch (error) {
      check(CancelToken.isCancel(error), 'read cancellation type');
    }
    await handle.removeReader('cancelled');
    final removedRead = handle.read('removed', 0, 20 * pieceLength, 4096);
    // Attach the expectation before removing a reader, so the RPC error is owned.
    final removedResult = removedRead.then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await handle.removeReader('removed');
    final removedError = await removedResult.timeout(
      const Duration(seconds: 2),
    );
    check(
      removedError is StateError &&
          removedError.toString().contains('cancelled'),
      'removing a blocked reader wakes it without polling or a caller cancel token',
    );
    await handle.pause();
    await handle.close();
    final previousRequests = fixture.requests.length;
    final restored = await engine
        .open(metadata, directory)
        .timeout(const Duration(seconds: 20));
    final restoredBytes = await restored
        .read('restore', 0, 0, 4096)
        .timeout(const Duration(seconds: 5));
    check(
      restoredBytes.toString() == first.toString(),
      'persisted bytes retained',
    );
    check(
      !fixture.requests.skip(previousRequests).contains(0),
      'verified persisted piece is not redownloaded',
    );
    await restored.close();
    final offline = await engine.open(metadata, directory, allowNetwork: false);
    final offlineRequests = fixture.requests.length;
    final cached = await offline.read('offline', 0, 0, 4096);
    check(
      cached.toString() == first.toString(),
      'offline verified cache playback',
    );
    check(
      fixture.requests.length == offlineRequests,
      'offline reader does not contact swarm',
    );
    await offline.close();
    final cachedFile = await File(
      '${directory.path}/${metadata.files.first.name}',
    ).open(mode: FileMode.writeOnlyAppend);
    await cachedFile.setPosition(0);
    await cachedFile.writeFrom([55]);
    await cachedFile.close();
    final damaged = await engine.open(metadata, directory, allowNetwork: false);
    try {
      await damaged.read('damaged', 0, 0, 4096);
      throw StateError('corrupted cached bytes were served');
    } on StateError catch (error) {
      check(
        error.toString().contains('缓存不完整'),
        'corrupted resume piece is rejected',
      );
    }
    await damaged.close();
    final magnet = await engine
        .resolve(fixture.magnet)
        .timeout(const Duration(seconds: 20));
    check(magnet.infoHash == metadata.infoHash, 'BEP9 real peer metadata');
    stdout.writeln(
      'PASS real BT download, verified head/tail seek, blocked read cancellation, disk resume, BEP9 magnet metadata',
    );
    stdout.writeln(
      'TIMING controlled loopback: metadata=${metadataClock.elapsedMilliseconds}ms '
      'initialize=${initializeClock.elapsedMilliseconds}ms '
      'first-piece=${firstPieceClock.elapsedMilliseconds}ms '
      'tail-seek=${seekClock.elapsedMilliseconds}ms',
    );
  } finally {
    diagnosis?.cancel();
    await engine.dispose().timeout(const Duration(seconds: 3));
    stdout.writeln('cleanup engine stopped');
    await fixture.close().timeout(const Duration(seconds: 3));
    stdout.writeln('cleanup fixture stopped');
    await directory.delete(recursive: true).timeout(const Duration(seconds: 3));
    stdout.writeln('cleanup files removed');
  }
  await _multiFile();
  await _workerCrash();
  await _metadataProxy();
  await _startupCancellation();
  await _stateFileIo();
}

Future<void> _stateFileIo() async {
  final fixture = TorrentLoopbackFixture(data: Uint8List(16 * 16384));
  final directory = await Directory.systemTemp.createTemp(
    'monogatari-bt-state-',
  );
  await fixture.start();
  final model = bt.TorrentParser.parseBytes(fixture.torrentBytes);
  final state = await bt.StateFileV2.getStateFile(directory.path, model);
  try {
    final handles = await Future.wait(
      List.generate(16, (_) => state.getAccess()),
    );
    check(
      handles.toSet().length == 1,
      'concurrent state opens share one descriptor',
    );
    final writes = List.generate(16, (index) => state.updateBitfield(index));
    await Future.wait([
      Future.wait(writes),
      state.close(),
    ]).timeout(const Duration(seconds: 5));
    final restored = await bt.StateFileV2.getStateFile(directory.path, model);
    try {
      check(
        restored.bitfield.completedPieces.length == 16,
        'close drains submitted state writes before releasing its descriptor',
      );
    } finally {
      await restored.close();
    }
    await directory.delete(recursive: true);
    stdout.writeln(
      'PASS concurrent resume-state writes drain on close without leaking file handles',
    );
  } finally {
    await state.close();
    await fixture.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

Future<void> _multiFile() async {
  const before = 2 * 16384 + 7, video = 12 * 16384 + 17, after = 8 * 16384;
  final fixture = TorrentLoopbackFixture(
    name: 'collection',
    files: [('skip.txt', before), ('episode.mp4', video), ('other.bin', after)],
    data: Uint8List.fromList(
      List.generate(before + video + after, (index) => (index * 29) & 255),
    ),
  );
  final directory = await Directory.systemTemp.createTemp(
    'monogatari-bt-batch-',
  );
  final engine = DartTorrentEngine(allowLoopbackPeers: true);
  await fixture.start();
  try {
    final metadata = await engine.resolve(fixture.source);
    final handle = await engine.open(metadata, directory);
    check(fixture.requests.isEmpty, 'batch initialization starts paused');
    await handle.download({1});
    final bytes = await handle
        .read('batch', 1, 256, 4096)
        .timeout(const Duration(seconds: 10));
    check(
      bytes.toString() ==
          fixture.data.sublist(before + 256, before + 256 + 4096).toString(),
      'selected multi-file offsets',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while ((await handle.snapshot()).files[1].downloadedBytes != video) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('selected multi-file download did not complete');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final first = before ~/ 16384, last = (before + video - 1) ~/ 16384;
    check(
      fixture.requests.every((piece) => piece >= first && piece <= last),
      'other batch files are skipped except shared boundary pieces',
    );
    await handle.close();
    stdout.writeln(
      'PASS real selected-file download with shared torrent piece boundaries',
    );
  } finally {
    await engine.dispose();
    await fixture.close();
    await directory.delete(recursive: true);
  }
}

Future<void> _startupCancellation() async {
  final fixture = TorrentLoopbackFixture(data: Uint8List(32 * 16384));
  final directory = await Directory.systemTemp.createTemp(
    'monogatari-bt-cancel-',
  );
  final engine = DartTorrentEngine(allowLoopbackPeers: true);
  await fixture.start();
  try {
    final metadata = await engine.resolve(fixture.source);
    final token = CancelToken();
    final opening = engine.open(metadata, directory, cancelToken: token);
    scheduleMicrotask(() => token.cancel('cancel initialization'));
    try {
      await opening.timeout(const Duration(seconds: 2));
      throw StateError('cancelled initialization returned a task');
    } on DioException catch (error) {
      check(CancelToken.isCancel(error), 'initialization cancellation type');
    }
    await engine.dispose().timeout(const Duration(seconds: 3));
    await directory.delete(recursive: true).timeout(const Duration(seconds: 3));
    stdout.writeln(
      'PASS initialization cancellation closes file and network resources promptly',
    );
  } finally {
    await engine.dispose();
    await fixture.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

void _crashingWorker(List<dynamic> arguments) {
  final commands = ReceivePort();
  (arguments.first as SendPort).send({'port': commands.sendPort});
  commands.listen((_) => throw StateError('intentional isolated worker crash'));
}

Future<void> _workerCrash() async {
  var attempts = 0;
  final fixture = TorrentLoopbackFixture(data: Uint8List(16384));
  await fixture.start();
  final engine = DartTorrentEngine(
    workerSpawner: (entry, args, {required onError, required onExit}) =>
        Isolate.spawn(
          attempts++ == 0 ? _crashingWorker : entry,
          args,
          onError: onError,
          onExit: onExit,
          errorsAreFatal: true,
        ),
  );
  try {
    try {
      await engine.resolve(fixture.source).timeout(const Duration(seconds: 2));
      throw StateError('worker crash did not fail the pending operation');
    } on StateError catch (error) {
      check(
        error.toString().contains('后台引擎'),
        'worker crash fails pending operation',
      );
    }
    final metadata = await engine
        .resolve(fixture.source)
        .timeout(const Duration(seconds: 5));
    check(
      metadata.files.single.size == 16384,
      'worker is recreated after fatal exit',
    );
    stdout.writeln(
      'PASS worker fatal exit fails promptly and a subsequent operation restarts it',
    );
  } finally {
    await engine.dispose();
    await fixture.close();
  }
}

Future<void> _metadataProxy() async {
  final fixture = TorrentLoopbackFixture(data: Uint8List(16384));
  await fixture.start();
  final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var requests = 0;
  proxy.listen((request) async {
    requests++;
    request.response.add(fixture.torrentBytes);
    await request.response.close();
  });
  final engine = DartTorrentEngine(
    metadataProxy: (_) => 'http://127.0.0.1:${proxy.port}',
  );
  try {
    final metadata = await engine
        .resolve(Uri.parse('http://metadata.fixture.invalid/movie.torrent'))
        .timeout(const Duration(seconds: 5));
    check(
      metadata.files.single.size == 16384 && requests == 1,
      'HTTP metadata uses configured source-specific proxy',
    );
    stdout.writeln('PASS torrent HTTP metadata follows injected HTTP proxy');
  } finally {
    await engine.dispose();
    await proxy.close(force: true);
    await fixture.close();
  }
}
