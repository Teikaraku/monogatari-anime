import 'dart:io';

import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/app_module.dart';
import 'package:kazumi/core_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/repositories/history_repository.dart';
import 'package:kazumi/services/api_video/api_video_service.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/player/history_playback_service.dart';
import 'package:kazumi/services/player/playback_source_preferences.dart';
import 'package:kazumi/services/rss/rss_playback_resolver.dart';
import 'package:kazumi/services/rss/rss_subscription_service.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:kazumi/services/torrent/torrent_background_coordinator.dart';
import 'package:kazumi/services/storage/storage.dart';
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
      'monogatari_core_module_',
    );
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    expect(path.isWithin(Directory.systemTemp.path, directory.path), isTrue);
    expect(
      path.basename(directory.path),
      startsWith('monogatari_core_module_'),
    );
    await directory.delete(recursive: true);
  });

  test(
    'real core registrations bootstrap and resolve the production downloader',
    () {
      // Register the real module, rather than reconstructing its factories in
      // the test. Optional callback constructors otherwise break AutoInjector's
      // runtime-type parser before InitPage is ever reached on the device.
      final boot = bootstrapModule(coreModule);
      addTearDown(boot.injector.dispose);

      final downloader = boot.injector.get<IDownloadManager>();
      expect(downloader, isA<DownloadManager>());
      expect(boot.injector.get<IDownloadManager>(), same(downloader));
      expect(boot.injector.get<IHistoryRepository>(), isA<HistoryRepository>());
      expect(boot.injector.get<ApiVideoService>(), isA<ApiVideoService>());
      final preferences = boot.injector.get<PlaybackSourcePreferences>();
      expect(boot.injector.get<PlaybackSourcePreferences>(), same(preferences));
      final rss = boot.injector.get<RssPlaybackResolver>();
      expect(
        rss.subscriptions,
        same(boot.injector.get<RssSubscriptionService>()),
      );
      expect(rss.torrents, same(boot.injector.get<TorrentService>()));
      expect(
        boot.injector.get<TorrentBackgroundCoordinator>().torrents,
        same(rss.torrents),
      );
      expect(
        boot.injector.get<DownloadController>(),
        isA<DownloadController>(),
      );
    },
  );

  test(
    'production app composition can bootstrap the same root dependency graph',
    () {
      final boot = bootstrapModule(appModule);
      addTearDown(boot.injector.dispose);

      expect(boot.injector.get<IDownloadManager>(), isA<DownloadManager>());
      expect(boot.injector.get<IHistoryRepository>(), isA<HistoryRepository>());
      expect(
        boot.injector.get<HistoryPlaybackService>(),
        isA<HistoryPlaybackService>(),
      );
      expect(
        boot.injector.get<DownloadController>(),
        isA<DownloadController>(),
      );
    },
  );
  test(
    'RSS player constructor resolves the real scoped dependency signature',
    () {
      final boot = bootstrapModule(
        createModule(
          register: (c) {
            c.module(coreModule);
            c.add<VideoPageController>(VideoPageController.withRss);
          },
        ),
      );
      addTearDown(boot.injector.dispose);
      final player = boot.injector.get<VideoPageController>();
      expect(
        player.rssPlayback,
        same(boot.injector.get<RssPlaybackResolver>()),
      );
      player.dispose();
    },
  );
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.directory);
  final String directory;

  @override
  Future<String?> getApplicationSupportPath() async => directory;
}
