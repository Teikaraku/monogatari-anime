import 'package:kazumi/utils/app_brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/widget/error_widget.dart';
import 'package:kazumi/bean/widget/image_preview.dart';
import 'package:kazumi/pages/collect/collect_module.dart';
import 'package:kazumi/pages/index_page.dart';
import 'package:kazumi/pages/info/info_module.dart';
import 'package:kazumi/pages/init_page.dart';
import 'package:kazumi/pages/my/my_module.dart';
import 'package:kazumi/pages/popular/popular_controller.dart';
import 'package:kazumi/pages/popular/popular_module.dart';
import 'package:kazumi/pages/route_error_page.dart';
import 'package:kazumi/pages/search/search_module.dart';
import 'package:kazumi/pages/settings/settings_module.dart';
import 'package:kazumi/pages/timeline/timeline_controller.dart';
import 'package:kazumi/pages/timeline/timeline_module.dart';
import 'package:kazumi/pages/video/video_module.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/services/sync/danmaku_shield_sync_service.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/subscriptions/subscriptions_page.dart';
import 'package:kazumi/services/sync/rss_sync_service.dart';
import 'package:kazumi/pages/torrent/torrent_tasks_page.dart';
import 'package:kazumi/services/rss/rss_subscription_service.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:kazumi/services/torrent/torrent_background_coordinator.dart';

final _tabTransition = CustomTransition(
  duration: const Duration(milliseconds: 70),
  transitionsBuilder: (context, animation, secondaryAnimation, child) {
    return FadeTransition(opacity: animation, child: child);
  },
);

final _imagePreviewTransition = CustomTransition(
  duration: const Duration(milliseconds: 220),
  transitionsBuilder: (context, animation, secondaryAnimation, child) {
    return FadeTransition(opacity: animation, child: child);
  },
);

final tabModule = createModule(
  path: '/tab',
  register: (c) {
    c
      // Tab state survives tab switches, but is released with the whole shell.
      ..addSingleton<PopularController>(PopularController.new)
      ..addSingleton<TimelineController>(TimelineController.new)
      ..route(
        '/',
        child: (context, state) => IndexPage(location: state.uri.path),
        transition: _tabTransition,
        children: (sub) {
          sub
            ..route(
              '/',
              guards: [
                (state) => GStorage.getSetting(SettingsKeys.defaultStartupPage),
              ],
              child: (context, state) => const SizedBox.shrink(),
            )
            ..module(popularModule)
            ..module(timelineModule)
            ..module(collectModule)
            ..module(myModule);
        },
      );
  },
);

final indexModule = createModule(
  register: (c) {
    c
      ..route(
        '/',
        child: (context, state) => InitPage(
          collectController: inject<CollectController>(),
          shaderAssetService: inject<ShaderAssetService>(),
          myController: inject<MyController>(),
          downloadController: inject<DownloadController>(),
          danmakuShieldSync: inject<DanmakuShieldSyncService>(),
          initializeSubscriptions: () async {
            inject<TorrentBackgroundCoordinator>().start();
            final service = inject<RssSubscriptionService>();
            await service.initialize();
            await service.startAutoRefresh();
            inject<RssSyncService>().start();
          },
        ),
        transition: TransitionType.none,
      )
      ..route(
        '/error',
        child: (context, state) => Scaffold(
          appBar: AppBar(title: const Text(AppBrand.name)),
          body: const GeneralErrorWidget(title: '初始化失败', errMsg: '请重新启动应用后再试。'),
        ),
      )
      ..module(tabModule)
      ..module(videoModule)
      ..route(
        '/subscriptions/',
        child: (context, state) => SubscriptionsPage(
          service: inject<RssSubscriptionService>(),
          torrentService: inject<TorrentService>(),
          subject: state.arguments is BangumiItem
              ? state.arguments as BangumiItem
              : null,
        ),
      )
      ..route(
        '/torrent-tasks/',
        child: (context, state) => TorrentTasksPage(
          service: inject<TorrentService>(),
          subjectId: state.arguments is int ? state.arguments as int : null,
        ),
      )
      ..route(
        ImageViewer.routePath,
        child: (context, state) {
          final args = state.arguments;
          if (args is! ImageViewerRouteArgs) {
            return const RouteErrorPage(message: '图片预览参数无效，请返回后重试。');
          }
          return ImageViewer(
            imageUrls: args.imageUrls,
            initialIndex: args.initialIndex,
            heroTag: args.heroTag,
          );
        },
        transition: _imagePreviewTransition,
      )
      ..module(infoModule)
      ..module(settingsModule)
      ..module(searchModule);
  },
);
