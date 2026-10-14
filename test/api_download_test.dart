import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart' hide ProgressCallback;
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/api_video/api_video_service.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/download/download_playlist_identity.dart';
import 'package:kazumi/utils/m3u8_parser.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp(
      'monogatari_api_download_',
    );
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
    await GStorage.putSetting(SettingsKeys.downloadDanmaku, false);
    await GStorage.putSetting(SettingsKeys.downloadParallelEpisodes, 1);
    await GStorage.putSetting(SettingsKeys.downloadParallelSegments, 1);
  });

  tearDownAll(() async {
    DioFactory.reset();
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    expect(path.isWithin(Directory.systemTemp.path, directory.path), isTrue);
    expect(
      path.basename(directory.path),
      startsWith('monogatari_api_download_'),
    );
    await directory.delete(recursive: true);
  });

  test(
    'download keeps API identity and automatically tries the next provider',
    () async {
      final repository = _MemoryDownloads();
      final manager = _QueuedManager();
      final service = _VideoService();
      final controller = DownloadController(repository, manager, service);
      await controller.init();
      const target = ApiVideoEpisode(
        key: '12.5',
        title: '第12.5集',
        number: 12.5,
      );

      await controller.startAutomaticDownload(
        subject: _subject(),
        episode: target,
        episodeNumber: 13,
      );
      await _until(() => manager.requests.isNotEmpty);
      final first = manager.requests.single;
      expect(first.pluginName, apiPlaybackLibraryName);
      expect(first.adBlockerEnabled, isTrue);
      expect(first.publicNetworkOnly, isTrue);
      expect(first.m3u8Url, 'https://zy1080.example/12.5.m3u8');
      final record = repository.getRecord('${apiPlaybackLibraryName}_123')!;
      expect(record.sourceSubject?.airDate, '2024-10-01');
      expect(record.episodes[13]!.apiEpisodeNumber, 12.5);
      expect(record.episodes[13]!.apiEpisodeKey, '12.5');
      expect(
        record.episodes[13]!.episodePageUrl,
        apiEpisodePageUrl(123, target),
      );
      final second = await first.resolveNextCandidate!(CancelToken());
      expect(second!.m3u8Url, 'https://baofeng.example/12.5.m3u8');
      expect(await second.resolveNextCandidate!(CancelToken()), isNull);
      expect(service.targets.every((e) => e.number == 12.5), isTrue);
    },
  );

  test(
    'a reordered catalog finds completed episodes by their stable identity',
    () async {
      final repository = _MemoryDownloads();
      final completedByKey = _episode(status: DownloadStatus.completed)
        ..episodeNumber = 7
        ..apiEpisodeKey = '2'
        ..apiEpisodeNumber = 2
        ..localM3u8Path = '/completed/7/playlist.m3u8';
      const episodeWithKey = ApiVideoEpisode(key: '2', title: '第2集', number: 2);
      const episodeWithUrl = ApiVideoEpisode(key: '3', title: '第3集', number: 3);
      final completedByUrl = _episode(status: DownloadStatus.completed)
        ..episodeNumber = 8
        ..episodePageUrl = apiEpisodePageUrl(123, episodeWithUrl)
        ..localM3u8Path = '/completed/8/playlist.m3u8';
      final record = DownloadRecord(
        123,
        'anime',
        '',
        apiPlaybackLibraryName,
        {7: completedByKey, 8: completedByUrl},
        DateTime(2026),
        sourceSubject: _subject(),
      );
      await repository.putRecord(record);
      final manager = _QueuedManager();
      final controller = DownloadController(
        repository,
        manager,
        _VideoService(),
      );
      await controller.init();
      await controller.startAutomaticDownload(
        subject: _subject(),
        episode: episodeWithKey,
        episodeNumber: 1,
      );
      await controller.startAutomaticDownload(
        subject: _subject(),
        episode: episodeWithUrl,
        episodeNumber: 2,
      );
      expect(manager.requests, isEmpty);
      expect(record.episodes.keys, [7, 8]);
      expect(
        controller.getAutomaticDownloadEpisode(123, episodeWithKey),
        same(completedByKey),
      );
      expect(
        controller.getAutomaticDownloadEpisode(123, episodeWithUrl),
        same(completedByUrl),
      );
      expect(completedByKey.localM3u8Path, '/completed/7/playlist.m3u8');
      expect(completedByUrl.localM3u8Path, '/completed/8/playlist.m3u8');
    },
  );

  test(
    'an occupied catalog ordinal allocates a different download storage slot',
    () async {
      final repository = _MemoryDownloads();
      final completed = _episode(status: DownloadStatus.completed)
        ..apiEpisodeKey = '9'
        ..apiEpisodeNumber = 9
        ..downloadDirectory = '/completed/1'
        ..localM3u8Path = '/completed/1/playlist.m3u8';
      final record = DownloadRecord(
        123,
        'anime',
        '',
        apiPlaybackLibraryName,
        {1: completed},
        DateTime(2026),
        sourceSubject: _subject(),
      );
      await repository.putRecord(record);
      final manager = _QueuedManager();
      final controller = DownloadController(
        repository,
        manager,
        _VideoService(),
      );
      await controller.init();
      await controller.startAutomaticDownload(
        subject: _subject(),
        episode: const ApiVideoEpisode(key: '1', title: '第1集', number: 1),
        episodeNumber: 1,
      );
      await _until(() => manager.requests.isNotEmpty);
      expect(manager.requests.single.episodeNumber, 2);
      expect(record.episodes[2]!.apiEpisodeKey, '1');
      expect(record.episodes[2]!.episodeNumber, 2);
      expect(record.episodes[2]!.danmakuQueryEpisodeNumber, 1);
      expect(record.episodes[1], same(completed));
      expect(completed.episodeNumber, 1);
      expect(completed.status, DownloadStatus.completed);
      expect(completed.localM3u8Path, '/completed/1/playlist.m3u8');
    },
  );

  test(
    'retry after a catalog reorder retains the failed episode storage slot',
    () async {
      final repository = _MemoryDownloads();
      final failed = _episode(status: DownloadStatus.failed)
        ..episodeNumber = 13
        ..apiEpisodeKey = '12.5'
        ..apiEpisodeNumber = 12.5
        ..downloadDirectory = '/partial/13';
      final record = DownloadRecord(
        123,
        'anime',
        '',
        apiPlaybackLibraryName,
        {13: failed},
        DateTime(2026),
        sourceSubject: _subject(),
      );
      await repository.putRecord(record);
      final manager = _QueuedManager();
      final controller = DownloadController(
        repository,
        manager,
        _VideoService(),
      );
      await controller.init();
      await controller.startAutomaticDownload(
        subject: _subject(),
        episode: const ApiVideoEpisode(
          key: '12.5',
          title: '第12.5集',
          number: 12.5,
        ),
        episodeNumber: 1,
      );
      await _until(() => manager.requests.isNotEmpty);
      expect(record.episodes.keys, [13]);
      expect(manager.requests.single.episodeNumber, 13);
      expect(manager.requests.single.episode.apiEpisodeNumber, 12.5);
      expect(manager.requests.single.episode.downloadDirectory, '/partial/13');
    },
  );

  test('pausing an API lookup never enqueues a late download', () async {
    final repository = _MemoryDownloads();
    final manager = _QueuedManager();
    final pending = Completer<void>();
    final service = _VideoService(hold: pending.future);
    final controller = DownloadController(repository, manager, service);
    await controller.init();
    await controller.startAutomaticDownload(
      subject: _subject(),
      episode: const ApiVideoEpisode(key: '1', title: '第1集', number: 1),
      episodeNumber: 1,
    );
    await _until(() => service.targets.isNotEmpty);
    await controller.pauseDownload(123, apiPlaybackLibraryName, 1);
    pending.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(manager.requests, isEmpty);
    expect(
      repository.getEpisode(123, apiPlaybackLibraryName, 1)!.status,
      DownloadStatus.paused,
    );
  });

  test('an old worker finishing pause cannot cancel a new API retry', () async {
    final repository = _MemoryDownloads();
    final manager = _QueuedManager();
    final controller = DownloadController(repository, manager, _VideoService());
    await controller.init();
    await controller.startAutomaticDownload(
      subject: _subject(),
      episode: const ApiVideoEpisode(key: '1', title: '第1集', number: 1),
      episodeNumber: 1,
    );
    await _until(() => manager.requests.length == 1);
    final oldEpisode = manager.requests.single.episode
      ..status = DownloadStatus.downloading;
    manager.onProgress!('${apiPlaybackLibraryName}_123', 1, oldEpisode, 0);
    await controller.pauseDownload(123, apiPlaybackLibraryName, 1);
    manager.onCancel = (_, _) => scheduleMicrotask(() {
      oldEpisode.status = DownloadStatus.paused;
    });
    await controller.retryDownload(
      bangumiId: 123,
      pluginName: apiPlaybackLibraryName,
      episodeNumber: 1,
    );
    await _until(() => manager.requests.length == 2);
    expect(manager.requests.last.episode, isNot(same(oldEpisode)));
    expect(manager.requests.last.episode.apiEpisodeKey, '1');
  });

  test(
    'fractional or unnumbered API extras do not query another episode danmaku',
    () {
      final recap = _episode()
        ..episodeNumber = 30
        ..apiEpisodeKey = '12.5'
        ..apiEpisodeNumber = 12.5;
      final special = _episode()
        ..episodeNumber = 31
        ..apiEpisodeKey = 'extra:ova';
      expect(recap.danmakuQueryEpisodeNumber, isNull);
      expect(special.danmakuQueryEpisodeNumber, isNull);
      expect((_episode()..episodeNumber = 9).danmakuQueryEpisodeNumber, 9);
    },
  );

  test(
    'legacy downloads resume through the API without deleting completed files',
    () async {
      final repository = _MemoryDownloads();
      final paused = _episode(status: DownloadStatus.paused);
      final completed = _episode(status: DownloadStatus.completed)
        ..episodeNumber = 2;
      final record = DownloadRecord(123, '夏目友人帐第七季', '', '旧规则', {
        1: paused,
        2: completed,
      }, DateTime(2026));
      await repository.putRecord(record);
      final manager = _QueuedManager();
      final service = _VideoService();
      final controller = DownloadController(repository, manager, service);
      await controller.init();
      await controller.retryDownload(
        bangumiId: 123,
        pluginName: '旧规则',
        episodeNumber: 1,
      );
      await _until(() => manager.requests.isNotEmpty);
      expect(manager.requests.single.pluginName, '旧规则');
      expect(service.subjects.single.nameCn, '夏目友人帐第七季');
      expect(record.episodes[2], same(completed));
      expect(completed.status, DownloadStatus.completed);
    },
  );

  test(
    'network failure switches provider and replaces only partial media',
    () async {
      final mediaDirectory = Directory(path.join(directory.path, 'fallback'));
      await mediaDirectory.create();
      await File(
        path.join(mediaDirectory.path, 'seg_00000.ts'),
      ).writeAsString('old');
      await File(
        path.join(mediaDirectory.path, 'danmaku.json'),
      ).writeAsString('[]');
      await File(
        path.join(mediaDirectory.path, 'notes.txt'),
      ).writeAsString('keep');
      final episode = _episode()..downloadDirectory = mediaDirectory.path;
      DioFactory.downloadDio.httpClientAdapter = _MediaAdapter();
      final manager = DownloadManager();
      final done = Completer<void>();
      manager.onProgress = (_, _, current, _) {
        if (current.status == DownloadStatus.completed && !done.isCompleted) {
          done.complete();
        }
      };
      var switches = 0;
      await manager.enqueue(
        _request(
          episode,
          'https://media.example/broken.m3u8',
          next: (token) async {
            switches++;
            return _request(episode, 'https://media.example/good.m3u8');
          },
        ),
      );
      await done.future.timeout(const Duration(seconds: 5));
      expect(switches, 1);
      expect(episode.networkM3u8Url, 'https://media.example/good.m3u8');
      expect(
        await File(
          path.join(mediaDirectory.path, 'seg_00000.ts'),
        ).readAsBytes(),
        List<int>.filled(188, 0x47),
      );
      expect(
        await File(
          path.join(mediaDirectory.path, 'danmaku.json'),
        ).readAsString(),
        '[]',
      );
      expect(
        await File(path.join(mediaDirectory.path, 'notes.txt')).readAsString(),
        'keep',
      );
    },
  );

  test('a storage failure does not retry other providers', () async {
    final invalidDirectory = File(
      path.join(directory.path, 'cannot_be_a_directory'),
    );
    await invalidDirectory.writeAsString('file');
    final episode = _episode()..downloadDirectory = invalidDirectory.path;
    final manager = DownloadManager();
    final failed = Completer<void>();
    manager.onProgress = (_, _, current, _) {
      if (current.status == DownloadStatus.failed && !failed.isCompleted) {
        failed.complete();
      }
    };
    var switches = 0;
    await manager.enqueue(
      _request(
        episode,
        'https://media.example/good.m3u8',
        next: (_) async {
          switches++;
          return null;
        },
      ),
    );
    await failed.future.timeout(const Duration(seconds: 5));
    expect(switches, 0);
  });

  test(
    'resume retains only media from the exact same playlist layout',
    () async {
      final episode = _episode()
        ..downloadDirectory = path.join(directory.path, 'playlist_identity');
      await Directory(episode.downloadDirectory).create();
      final segmentFile = File(
        path.join(episode.downloadDirectory, 'seg_00000.ts'),
      );
      final danmakuFile = File(
        path.join(episode.downloadDirectory, 'danmaku.json'),
      );
      final original = [
        M3u8Segment(
          duration: 4,
          uri: 'https://a/one.ts',
          discontinuityGroup: 0,
        ),
      ];
      await ensureDownloadPlaylistIdentity(
        episode,
        mediaUrl: 'https://a/master.m3u8',
        segments: original,
        adBlockerEnabled: false,
      );
      await segmentFile.writeAsString('partial');
      await danmakuFile.writeAsString('keep');
      await ensureDownloadPlaylistIdentity(
        episode,
        mediaUrl: 'https://a/master.m3u8',
        segments: original,
        adBlockerEnabled: false,
      );
      expect(await segmentFile.readAsString(), 'partial');
      await ensureDownloadPlaylistIdentity(
        episode,
        mediaUrl: 'https://a/master.m3u8',
        segments: [
          M3u8Segment(
            duration: 4,
            uri: 'https://a/other.ts',
            discontinuityGroup: 0,
          ),
        ],
        adBlockerEnabled: false,
      );
      expect(await segmentFile.exists(), isFalse);
      await segmentFile.writeAsString('partial');
      await ensureDownloadPlaylistIdentity(
        episode,
        mediaUrl: 'https://a/master.m3u8',
        segments: [
          M3u8Segment(
            duration: 4,
            uri: 'https://a/other.ts',
            discontinuityGroup: 0,
          ),
        ],
        adBlockerEnabled: true,
      );
      expect(await segmentFile.exists(), isFalse);
      expect(await danmakuFile.readAsString(), 'keep');
    },
  );

  test(
    'a 200 HTML response with generic MIME is rejected and switches source',
    () async {
      final episode = _episode()
        ..downloadDirectory = path.join(directory.path, 'html_direct');
      final adapter = _DirectMediaAdapter();
      DioFactory.downloadDio.httpClientAdapter = adapter;
      final manager = DownloadManager();
      final done = Completer<void>();
      manager.onProgress = (_, _, current, _) {
        if (current.status == DownloadStatus.completed && !done.isCompleted) {
          done.complete();
        }
      };
      var switches = 0;
      await manager.enqueue(
        _request(
          episode,
          'https://media.example/error.mp4',
          next: (_) async {
            switches++;
            return _request(episode, 'https://media.example/valid.mp4');
          },
        ),
      );
      await done.future.timeout(const Duration(seconds: 5));
      expect(switches, 1);
      expect(await File(episode.localM3u8Path).readAsBytes(), _mp4Header);
    },
  );

  test(
    'an HLS error page is never downgraded to a completed direct file',
    () async {
      final episode = _episode()
        ..downloadDirectory = path.join(directory.path, 'html_hls');
      final adapter = _DirectMediaAdapter();
      DioFactory.downloadDio.httpClientAdapter = adapter;
      final manager = DownloadManager();
      final done = Completer<void>();
      manager.onProgress = (_, _, current, _) {
        if (current.status == DownloadStatus.failed && !done.isCompleted) {
          done.complete();
        }
      };
      await manager.enqueue(
        _request(
          episode,
          'https://media.example/error.m3u8',
          sourceFormat: VideoSourceFormat.hls,
        ),
      );
      await done.future.timeout(const Duration(seconds: 5));
      expect(adapter.requests, 1);
      expect(
        await File(path.join(episode.downloadDirectory, 'video.mp4')).exists(),
        isFalse,
      );
      expect(episode.status, DownloadStatus.failed);
    },
  );

  test(
    'resuming waits for the cancelled worker to close its real file',
    () async {
      final mediaDirectory = path.join(directory.path, 'resume_direct');
      final episode = _episode()..downloadDirectory = mediaDirectory;
      final adapter = _SlowDirectAdapter();
      DioFactory.downloadDio.httpClientAdapter = adapter;
      final closeStarted = Completer<void>();
      final allowClose = Completer<void>();
      var openedFiles = 0;
      var firstFileClosed = false;
      final manager = DownloadManager(
        openDirectFile: (file, mode) async {
          openedFiles++;
          final realFile = await file.open(mode: mode);
          if (openedFiles == 1) {
            return _DelayedCloseFile(
              realFile,
              closeStarted,
              allowClose.future,
              () => firstFileClosed = true,
            );
          }
          expect(firstFileClosed, isTrue);
          return realFile;
        },
      )..maxParallelEpisodes = 2;
      final gotBytes = Completer<void>();
      final completed = Completer<void>();
      manager.onProgress = (_, _, current, _) {
        if (current.totalBytes > 0 && !gotBytes.isCompleted) {
          gotBytes.complete();
        }
        if (current.status == DownloadStatus.completed &&
            !completed.isCompleted) {
          completed.complete();
        }
      };
      await manager.enqueue(
        _request(episode, 'https://media.example/valid.mp4'),
      );
      await gotBytes.future.timeout(const Duration(seconds: 5));
      manager.pause('${apiPlaybackLibraryName}_123', 1);
      await closeStarted.future.timeout(const Duration(seconds: 5));
      final resumed = _episode()
        ..downloadDirectory = mediaDirectory
        ..networkM3u8Url = 'https://media.example/valid.mp4';
      await manager.resume(
        _request(resumed, 'https://media.example/valid.mp4'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(adapter.streamRequests, 1);
      allowClose.complete();
      await completed.future.timeout(const Duration(seconds: 5));
      expect(firstFileClosed, isTrue);
      expect(await File(resumed.localM3u8Path).readAsBytes(), _mp4Header);
    },
  );

  test(
    'download metadata persists and legacy Hive fields remain readable',
    () async {
      final legacyEpisode = DownloadEpisodeAdapter().read(
        _FieldsReader({
          0: 1,
          1: '第1集',
          2: 0,
          3: DownloadStatus.completed,
          4: 1.0,
          5: 1,
          6: 1,
          7: '/old/playlist.m3u8',
          8: '/old',
          9: '',
          10: DateTime(2026),
        }),
      );
      final legacyRecord = DownloadRecordAdapter().read(
        _FieldsReader({
          0: 123,
          1: 'old',
          2: '',
          3: '旧规则',
          4: <int, DownloadEpisode>{1: legacyEpisode},
          5: DateTime(2026),
        }),
      );
      expect(legacyRecord.sourceSubject, isNull);
      expect(legacyEpisode.apiEpisodeKey, isEmpty);
      expect(legacyEpisode.apiEpisodeNumber, isNull);
      expect(legacyEpisode.localM3u8Path, '/old/playlist.m3u8');
      final episode = _episode()
        ..apiEpisodeNumber = 12.5
        ..apiEpisodeKey = '12.5';
      final record = DownloadRecord(
        123,
        'anime',
        '',
        apiPlaybackLibraryName,
        {13: episode},
        DateTime(2026),
        sourceSubject: _subject(),
      );
      var box = await Hive.openBox<DownloadRecord>('api_metadata');
      await box.put(record.key, record);
      await box.close();
      box = await Hive.openBox<DownloadRecord>('api_metadata');
      final restored = box.get(record.key)!;
      expect(restored.sourceSubject!.airDate, '2024-10-01');
      expect(restored.episodes[13]!.apiEpisodeNumber, 12.5);
      expect(restored.episodes[13]!.apiEpisodeKey, '12.5');
      await box.close();
    },
  );
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

BangumiItem _subject() => BangumiItem(
  id: 123,
  type: 2,
  name: 'Natsume',
  nameCn: '夏目友人帐第七季',
  summary: '',
  airDate: '2024-10-01',
  airWeekday: 0,
  rank: 0,
  images: {},
  tags: [],
  alias: [],
  ratingScore: 0,
  votes: 0,
  votesCount: [],
  info: '',
);

DownloadEpisode _episode({int status = DownloadStatus.resolving}) =>
    DownloadEpisode(1, '第1集', 0, status, 0, 0, 0, '', '', '', null, '', 0, '');

DownloadRequest _request(
  DownloadEpisode episode,
  String url, {
  Future<DownloadRequest?> Function(CancelToken)? next,
  VideoSourceFormat sourceFormat = VideoSourceFormat.auto,
}) => DownloadRequest(
  recordKey: '${apiPlaybackLibraryName}_123',
  bangumiId: 123,
  pluginName: apiPlaybackLibraryName,
  episodeNumber: 1,
  m3u8Url: url,
  httpHeaders: {},
  adBlockerEnabled: false,
  episode: episode,
  resolveNextCandidate: next,
  sourceFormat: sourceFormat,
);

class _VideoService implements ApiVideoService {
  _VideoService({this.hold});
  final Future<void>? hold;
  final subjects = <BangumiItem>[];
  final targets = <ApiVideoEpisode>[];

  @override
  Stream<ApiVideoCandidate> candidatesForEpisode(
    BangumiItem subject,
    ApiVideoEpisode episode, {
    CancelToken? cancelToken,
  }) async* {
    subjects.add(subject);
    targets.add(episode);
    if (hold != null) await hold;
    if (cancelToken?.isCancelled ?? false) return;
    for (final provider in [
      ApiVideoProvider.zy1080,
      ApiVideoProvider.baofeng,
    ]) {
      yield ApiVideoCandidate(
        provider: provider,
        id: 'id',
        title: subject.nameCn,
        episode: episode,
        url: 'https://${provider.id}.example/${episode.key}.m3u8',
        format: VideoSourceFormat.hls,
      );
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QueuedManager implements IDownloadManager {
  final requests = <DownloadRequest>[];
  @override
  ProgressCallback? onProgress;
  void Function(String, int)? onCancel;
  @override
  Future<void> enqueue(DownloadRequest request) async => requests.add(request);
  @override
  Future<void> enqueuePriority(DownloadRequest request) => enqueue(request);
  @override
  void pause(String recordKey, int episodeNumber) {}
  @override
  void cancel(String recordKey, int episodeNumber) =>
      onCancel?.call(recordKey, episodeNumber);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryDownloads implements IDownloadRepository {
  final data = <String, DownloadRecord>{};
  @override
  List<DownloadRecord> getAllRecords() => data.values.toList();
  @override
  DownloadRecord? getRecord(String key) => data[key];
  @override
  Future<void> putRecord(DownloadRecord record) async {
    data[record.key] = record;
  }

  @override
  Future<void> updateEpisode(
    String key,
    int number,
    DownloadEpisode episode,
  ) async {
    data[key]!.episodes[number] = episode;
  }

  @override
  DownloadEpisode? getEpisode(int id, String name, int number) =>
      data['${name}_$id']?.episodes[number];
  @override
  bool getForceAdBlocker() => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MediaAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path.endsWith('broken.m3u8')) {
      return ResponseBody.fromString('unavailable', 503);
    }
    if (options.uri.path.endsWith('.m3u8')) {
      return ResponseBody.fromString(
        '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nvideo.ts\n#EXT-X-ENDLIST\n',
        200,
      );
    }
    return ResponseBody.fromBytes(
      List<int>.filled(188, 0x47),
      200,
      headers: {
        'content-length': ['188'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final _mp4Header = <int>[
  0,
  0,
  0,
  24,
  ...'ftyp'.codeUnits,
  ...'isom'.codeUnits,
  0,
  0,
  0,
  0,
  ...'isom'.codeUnits,
  ...'mp42'.codeUnits,
];

class _DirectMediaAdapter implements HttpClientAdapter {
  var requests = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    final bytes = options.uri.path.contains('error')
        ? '<!doctype html><html>Access denied</html>'.codeUnits
        : _mp4Header;
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        'content-type': ['application/octet-stream'],
        'content-length': ['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _SlowDirectAdapter implements HttpClientAdapter {
  var streamRequests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.responseType != ResponseType.stream) {
      return ResponseBody.fromString('direct file', 200);
    }
    streamRequests++;
    if (streamRequests > 1) {
      // Return a full response to the Range request. The worker must replace
      // the partial MP4 instead of appending this complete file.
      return ResponseBody.fromBytes(
        _mp4Header,
        200,
        headers: {
          'content-length': ['${_mp4Header.length}'],
        },
      );
    }
    late StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>(
      onListen: () => controller.add(Uint8List.fromList(_mp4Header)),
    );
    return ResponseBody(
      controller.stream,
      200,
      headers: {
        'content-length': ['100000'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _DelayedCloseFile implements RandomAccessFile {
  _DelayedCloseFile(
    this.file,
    this.closeStarted,
    this.allowClose,
    this.onClosed,
  );
  final RandomAccessFile file;
  final Completer<void> closeStarted;
  final Future<void> allowClose;
  final void Function() onClosed;
  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) => file.writeFrom(buffer, start, end);
  @override
  Future<void> close() async {
    if (!closeStarted.isCompleted) closeStarted.complete();
    await allowClose;
    await file.close();
    onClosed();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FieldsReader implements BinaryReader {
  _FieldsReader(Map<int, Object?> fields)
    : values = [
        fields.length,
        for (final entry in fields.entries) ...[entry.key, entry.value],
      ];
  final List<Object?> values;
  var index = 0;
  @override
  int readByte() => values[index++]! as int;
  @override
  dynamic read([int? typeId]) => values[index++];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}
