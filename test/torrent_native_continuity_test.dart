import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/player/playback_cache_policy.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/torrent/dart_torrent_engine.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'support/torrent_loopback_fixture.dart';

void main() {
  test(
    'native RSS resumes after missing pieces, user pause and seek without restarting the swarm',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final oldPaths = PathProviderPlatform.instance;
      final directory = await Directory.systemTemp.createTemp(
        'monogatari-native-continuity-',
      );
      PathProviderPlatform.instance = _Paths(directory.path);
      Hive.init(directory.path);
      await GStorage.init();
      // Deterministic 50-second PCM fixture, carried over real BT pieces and
      // the production HTTP server. Its payload needs no platform video codec.
      final data = Uint8List(44 + 50 * 44100 * 2);
      final header = ByteData.sublistView(data);
      void label(int offset, String value) =>
          data.setRange(offset, offset + value.length, value.codeUnits);
      label(0, 'RIFF');
      header.setUint32(4, data.length - 8, Endian.little);
      label(8, 'WAVE');
      label(12, 'fmt ');
      header.setUint32(16, 16, Endian.little);
      header.setUint16(20, 1, Endian.little);
      header.setUint16(22, 1, Endian.little);
      header.setUint32(24, 44100, Endian.little);
      header.setUint32(28, 88200, Endian.little);
      header.setUint16(32, 2, Endian.little);
      header.setUint16(34, 16, Endian.little);
      label(36, 'data');
      header.setUint32(40, data.length - 44, Endian.little);
      final fixture = TorrentLoopbackFixture(data: data, pieceLength: 65536)
        ..withheld.add(13);
      await fixture.start();
      final service = TorrentService(
        engine: DartTorrentEngine(allowLoopbackPeers: true),
        directoryProvider: () async => Directory('${directory.path}/bt'),
      );
      MediaKit.ensureInitialized(
        libmpv: File('build/native_assets/windows/libmpv-2.dll').absolute.path,
      );
      final player = Player(
        configuration: const PlayerConfiguration(bufferSize: 32 * 1024 * 1024),
      );
      final policy = PlaybackCachePolicy(
        isLocalPlayback: () => false,
        isTorrentStream: () => true,
        currentPlayer: () => player,
      );
      dynamic lease;
      final errors = <String>[];
      final errorsSubscription = player.stream.error.listen(errors.add);
      Future<void> until(bool Function() predicate, {int seconds = 20}) async {
        final deadline = DateTime.now().add(Duration(seconds: seconds));
        while (!predicate()) {
          if (DateTime.now().isAfter(deadline))
            fail(
              'Playback did not advance: ${player.state.position}, buffering=${player.state.buffering}, errors=$errors',
            );
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      try {
        final task = await service.add(fixture.source);
        lease = await service.openStream(task.id, 0);
        final native = player.platform as NativePlayer;
        await native.setProperty('ao', 'null');
        await native.setProperty('vo', 'null');
        await native.setProperty('http-proxy', lease.url.origin);
        await native.setProperty('network-timeout', '90');
        await native.setProperty(
          'demuxer-lavf-o',
          'protocol_whitelist=[http,tcp,httpproxy,crypto]',
        );
        await policy.apply();
        await player.open(Media(lease.url.toString()));
        await until(() => player.state.position.inSeconds >= 1);
        await until(
          () => player.state.buffering && player.state.position.inSeconds > 1,
        );
        expect(player.state.playing, isTrue);
        final stalled = player.state.position;
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(double.parse(await native.getProperty('cache-pause-wait')), 8);
        fixture.release(13);
        await until(
          () => player.state.position > stalled + const Duration(seconds: 2),
        );
        await player.pause();
        final paused = player.state.position;
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(
          (player.state.position - paused).inMilliseconds.abs(),
          lessThan(200),
        );
        await player.play();
        await until(
          () => player.state.position > paused + const Duration(seconds: 1),
        );
        await player.seek(const Duration(seconds: 30));
        await until(() => player.state.position.inSeconds >= 31);
        expect(errors, isEmpty);
        expect(service.tasks, hasLength(1));
      } finally {
        fixture.release(13);
        policy.stopWatching();
        await lease?.close();
        await player.dispose();
        await errorsSubscription.cancel();
        await service.dispose();
        await fixture.close();
        await Hive.close();
        PathProviderPlatform.instance = oldPaths;
        HttpOverrides.global = overrides;
        expect(directory.parent.path, Directory.systemTemp.path);
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
    skip:
        !Platform.isWindows ||
        !File('build/native_assets/windows/libmpv-2.dll').existsSync(),
  );
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}
