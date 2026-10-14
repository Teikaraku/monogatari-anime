import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/my/watch_stats.dart';
import 'package:kazumi/pages/my/my_space_view.dart';
import 'package:kazumi/pages/subscriptions/subscriptions_page.dart';
import 'package:kazumi/pages/torrent/torrent_tasks_page.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/services/rss/rss_subscription_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/torrent/torrent_models.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  late Directory directory;
  late PathProviderPlatform originalPaths;
  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp(
      'monogatari_rss_ui_test_',
    );
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    expect(
      directory.absolute.path.startsWith(Directory.systemTemp.absolute.path),
      isTrue,
    );
    expect(
      directory.uri.pathSegments.where((part) => part.isNotEmpty).last,
      startsWith('monogatari_rss_ui_test_'),
    );
    await directory.delete(recursive: true);
  });

  testWidgets('My page exposes subscription and torrent task destinations', (
    tester,
  ) async {
    final opened = <MyDestination>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MySpaceView(stats: const WatchStats(), onOpen: opened.add),
        ),
      ),
    );
    await tester.tap(find.text('RSS 订阅'));
    await tester.tap(find.text('磁力任务'));
    expect(opened, [MyDestination.subscriptions, MyDestination.torrentTasks]);
  });

  testWidgets(
    'subscribing preserves the exact selected Mikan RSS subgroup id',
    (tester) async {
      final rss = _RssService()..resolvedShow = _show();
      final torrent = _TorrentService();
      addTearDown(rss.dispose);
      addTearDown(torrent.close);
      await tester.pumpWidget(
        MaterialApp(
          home: SubscriptionsPage(
            service: rss,
            torrentService: torrent,
            subject: _subject(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择字幕组'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('字幕组甲'));
      await tester.pumpAndSettle();

      expect(rss.selectedGroup?.id, 370);
      expect(rss.selectedGroup?.feedUri.queryParameters['subgroupid'], '370');
      expect(rss.subscribedSubject?.id, 400602);
      expect(rss.refreshedSubscriptionId, 'selected');
      expect(find.text('添加字幕组'), findsOneWidget);
    },
  );

  testWidgets('a searched show from another season cannot be subscribed', (
    tester,
  ) async {
    final rss = _RssService()
      ..searchResults = [_show(id: 9000, bangumiId: 123, title: '另一季度')];
    final torrent = _TorrentService();
    addTearDown(rss.dispose);
    addTearDown(torrent.close);
    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionsPage(
          service: rss,
          torrentService: torrent,
          subject: _subject(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索番组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('另一季度'));
    await tester.pumpAndSettle();

    expect(find.text('这个蜜柑番组与当前 Bangumi 条目不一致，请选择对应季度'), findsOneWidget);
    expect(rss.selectedGroup, isNull);
    expect(find.text('选择字幕组'), findsNothing);
  });

  testWidgets(
    'switching a saved subtitle group is explicit and updates its selected marker',
    (tester) async {
      final show = _show();
      final rss = _RssService()
        ..subscriptions = [
          RssSubscription(
            id: 'first',
            subject: _subject(),
            show: show,
            group: show.groups.single,
            createdAt: DateTime(2026),
          ),
          RssSubscription(
            id: 'second',
            subject: _subject(),
            show: show,
            group: MikanSubtitleGroup(
              id: 223,
              name: '字幕组乙',
              feedUri: Uri.parse(
                'https://mikanani.me/RSS/Bangumi?bangumiId=3141&subgroupid=223',
              ),
            ),
            createdAt: DateTime(2026),
          ),
        ]
        ..selectedId = 'first';
      final torrent = _TorrentService();
      addTearDown(rss.dispose);
      addTearDown(torrent.close);
      await tester.pumpWidget(
        MaterialApp(
          home: SubscriptionsPage(
            service: rss,
            torrentService: torrent,
            subject: _subject(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(rss.selectedId, 'first');
      Finder checkIn(String group) => find.descendant(
        of: find.ancestor(of: find.text(group), matching: find.byType(InkWell)),
        matching: find.byIcon(Icons.check_circle_rounded),
      );
      expect(checkIn('字幕组甲'), findsOneWidget);
      await tester.tap(find.text('字幕组乙'));
      await tester.pumpAndSettle();
      expect(rss.selectedId, 'second');
      expect(checkIn('字幕组乙'), findsOneWidget);
      expect(checkIn('字幕组甲'), findsNothing);
    },
  );

  testWidgets('release rows lead with the episode and list the title tags', (
    tester,
  ) async {
    final rss = _RssService()
      ..resolvedShow = _show()
      ..releases = [
        RssRelease(
          key: 'five',
          title:
              '[字幕组甲] 葬送的芙莉莲 / Sousou no Frieren [05][WebRip][1080p][HEVC_AAC][简繁日内封]',
          detailUri: Uri.parse('https://mikanani.me/Home/Episode/five'),
          episodeNumber: 5,
          quality: '1080p',
          group: '字幕组甲',
          bangumiId: 400602,
        ),
        RssRelease(
          key: 'batch',
          title: '[字幕组甲] 葬送的芙莉莲 [01-12 合集][1080p]',
          detailUri: Uri.parse('https://mikanani.me/Home/Episode/batch'),
          episodeNumbers: const [1, 12],
          isBatch: true,
          quality: '1080p',
          group: '字幕组甲',
          bangumiId: 400602,
        ),
      ];
    final torrent = _TorrentService();
    addTearDown(rss.dispose);
    addTearDown(torrent.close);
    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionsPage(
          service: rss,
          torrentService: torrent,
          subject: _subject(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('第 5 话'), findsOneWidget);
    expect(find.text('05'), findsOneWidget);
    expect(find.text('WebRip · HEVC_AAC · 简繁日内封'), findsOneWidget);
    expect(find.text('第 1–12 话'), findsOneWidget);
    // Nothing but the episode range is bracketed: the full title shows.
    expect(find.text('[字幕组甲] 葬送的芙莉莲 [01-12 合集][1080p]'), findsOneWidget);
  });

  testWidgets('releases since the last visit are marked new once', (
    tester,
  ) async {
    RssRelease release(String key, int day) => RssRelease(
      key: key,
      title: '[字幕组甲] 葬送的芙莉莲 [0$day]',
      detailUri: Uri.parse('https://mikanani.me/Home/Episode/$key'),
      episodeNumber: day.toDouble(),
      publishedAt: DateTime.utc(2026, 10, day),
      bangumiId: 400602,
    );
    final rss = _RssService()
      ..resolvedShow = _show()
      ..since = DateTime.utc(2026, 10, 3)
      ..releases = [release('new', 5), release('old', 2)];
    final torrent = _TorrentService();
    addTearDown(rss.dispose);
    addTearDown(torrent.close);
    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionsPage(
          service: rss,
          torrentService: torrent,
          subject: _subject(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('新'), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(of: find.text('第 5 话'), matching: find.byType(Row)),
        matching: find.text('新'),
      ),
      findsWidgets,
    );
    expect(rss.viewed, [400602]);
  });

  testWidgets(
    'leaving while matching cancels the UI request and ignores its late result',
    (tester) async {
      final pending = Completer<MikanShow?>();
      final rss = _RssService()..pendingResolve = pending.future;
      final torrent = _TorrentService();
      addTearDown(rss.dispose);
      addTearDown(torrent.close);
      await tester.pumpWidget(
        MaterialApp(
          home: SubscriptionsPage(
            service: rss,
            torrentService: torrent,
            subject: _subject(),
          ),
        ),
      );
      await tester.pump();
      expect(rss.resolveToken, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(rss.resolveToken!.isCancelled, isTrue);
      pending.complete(_show());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('initialization errors are visible and retry can recover', (
    tester,
  ) async {
    final rss = _RssService()
      ..initializeFailure = const RssException('订阅文件读取失败');
    final torrent = _TorrentService();
    addTearDown(rss.dispose);
    addTearDown(torrent.close);
    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionsPage(service: rss, torrentService: torrent),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('订阅文件读取失败'), findsOneWidget);
    rss.initializeFailure = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('订阅文件读取失败'), findsNothing);
    expect(find.text('还没有 RSS 订阅'), findsOneWidget);
  });

  testWidgets(
    'RSS retry and browsing do not wait for or duplicate BT startup',
    (tester) async {
      final rss = _RssService()
        ..initializeFailure = const RssException('订阅文件读取失败');
      final pending = Completer<void>();
      final torrent = _TorrentService()
        ..available = const TorrentCapability(supported: true, ready: false)
        ..initializeResult = pending.future;
      addTearDown(rss.dispose);
      addTearDown(torrent.close);
      await tester.pumpWidget(
        MaterialApp(
          home: SubscriptionsPage(service: rss, torrentService: torrent),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('订阅文件读取失败'), findsOneWidget);
      expect(torrent.initializeCalls, 1);
      rss.initializeFailure = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('还没有 RSS 订阅'), findsOneWidget);
      expect(torrent.initializeCalls, 1);

      // The engine belongs to the app: leaving this route must not cancel it or
      // let a late completion update disposed page state.
      await tester.pumpWidget(const SizedBox.shrink());
      pending.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('BT startup can fail and retry independently of RSS resources', (
    tester,
  ) async {
    final rss = _RssService()
      ..resolvedShow = _show()
      ..releases = [
        RssRelease(
          key: 'one',
          title: '已加载的第1话资源',
          detailUri: Uri.parse('https://mikanani.me/Home/Episode/one'),
          episodeNumber: 1,
          bangumiId: 400602,
        ),
      ];
    final torrent = _TorrentService()
      ..available = const TorrentCapability(supported: true, ready: false)
      ..initializeFailure = StateError('engine temporarily unavailable');
    addTearDown(rss.dispose);
    addTearDown(torrent.close);
    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionsPage(
          service: rss,
          torrentService: torrent,
          subject: _subject(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('磁力引擎启动失败，请重试'), findsOneWidget);
    expect(find.text('蜜柑 · 葬送的芙莉莲'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('播放'));
    await tester.pumpAndSettle();
    expect(_button(tester, '播放').onPressed, isNull);
    expect(_button(tester, '下载').onPressed, isNull);

    final pending = Completer<void>();
    torrent.initializeFailure = null;
    torrent.initializeResult = pending.future;
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    // The previous rendered button can receive a second tap in the same frame.
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(torrent.initializeCalls, 2);
    torrent.available = const TorrentCapability(supported: true, ready: true);
    torrent.capabilityController.add(torrent.available);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('磁力引擎启动失败，请重试'), findsNothing);
    await tester.ensureVisible(find.byTooltip('播放'));
    await tester.pumpAndSettle();
    expect(_button(tester, '播放').onPressed, isNotNull);
    expect(_button(tester, '下载').onPressed, isNotNull);
  });

  testWidgets('task progress updates build only visible task cards', (
    tester,
  ) async {
    final tasks = List.generate(40, (index) => _ObservedTask('task-$index'));
    final torrent = _TorrentService()..taskList = tasks;
    addTearDown(torrent.close);
    await tester.pumpWidget(
      MaterialApp(home: TorrentTasksPage(service: torrent)),
    );
    await tester.pumpAndSettle();
    expect(tasks.first.titleReads, greaterThan(0));
    expect(tasks.last.titleReads, 0);
    torrent.emit(tasks);
    await tester.pumpAndSettle();
    expect(tasks.last.titleReads, 0);
  });

  testWidgets('task reorder retains the expanded file list with its task', (
    tester,
  ) async {
    final first = _task(
      'first',
      state: TorrentTaskState.completed,
      files: const [
        TorrentFileInfo(
          index: 0,
          name: 'Episode01.mkv',
          size: 100,
          isVideo: true,
        ),
      ],
    );
    final second = _task('second', state: TorrentTaskState.completed);
    final torrent = _TorrentService()..taskList = [first, second];
    addTearDown(torrent.close);
    await tester.pumpWidget(
      MaterialApp(home: TorrentTasksPage(service: torrent)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 个视频文件'));
    await tester.pumpAndSettle();
    expect(find.text('Episode01.mkv'), findsOneWidget);
    torrent.emit([second, first]);
    await tester.pumpAndSettle();
    expect(find.text('Episode01.mkv'), findsOneWidget);
  });

  testWidgets(
    'task controls prevent duplicate pause and preserve tasks when route closes',
    (tester) async {
      final torrent = _TorrentService()..taskList = [_task('one')];
      final pause = Completer<void>();
      torrent.pauseResult = pause.future;
      addTearDown(torrent.close);
      await tester.pumpWidget(
        MaterialApp(
          home: TorrentTasksPage(service: torrent, subjectId: 400602),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('暂停'));
      await tester.tap(find.byTooltip('暂停'));
      await tester.pump();
      expect(torrent.paused, ['one']);
      pause.complete();
      await tester.pumpAndSettle();
      torrent.emit([
        _task('one', state: TorrentTaskState.paused),
        _task('other', subjectId: 123),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('已暂停'), findsOneWidget);
      expect(find.text('other'), findsNothing);
      await tester.tap(find.byTooltip('继续'));
      await tester.pumpAndSettle();
      expect(torrent.resumed, ['one']);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(torrent.tasksController.hasListener, isFalse);
      expect(torrent.capabilityController.hasListener, isFalse);
      expect(torrent.cancelled, isEmpty);
    },
  );

  testWidgets('deleting a task removes its downloaded files', (tester) async {
    final torrent = _TorrentService()
      ..taskList = [_task('one', state: TorrentTaskState.completed)];
    addTearDown(torrent.close);
    await tester.pumpWidget(
      MaterialApp(home: TorrentTasksPage(service: torrent)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('任务选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNothing);
    await tester.tap(find.text('删除任务'));
    await tester.pumpAndSettle();
    expect(torrent.deleted, [('one', true)]);
  });

  testWidgets(
    'cancelling a resource preparation never cancels a reused torrent task',
    (tester) async {
      final show = _show();
      final rss = _RssService()
        ..subscriptions = [
          RssSubscription(
            id: 'selected',
            subject: _subject(),
            show: show,
            group: show.groups.single,
            createdAt: DateTime(2026),
          ),
        ]
        ..selectedId = 'selected'
        ..releases = [
          RssRelease(
            key: 'release',
            title: '第1话资源',
            detailUri: Uri.parse('https://mikanani.me/Home/Episode/123'),
            torrentUri: Uri.parse('https://mikanani.me/Download/123.torrent'),
            episodeNumber: 1,
            bangumiId: 400602,
          ),
        ];
      final pending = Completer<TorrentTaskSnapshot>();
      final existing = _task('already-downloading');
      final torrent = _TorrentService()
        ..taskList = [existing]
        ..addResult = pending.future;
      addTearDown(rss.dispose);
      addTearDown(torrent.close);
      await tester.pumpWidget(
        MaterialApp(
          home: SubscriptionsPage(
            service: rss,
            torrentService: torrent,
            subject: _subject(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('下载'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下载'));
      await tester.pump();
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(torrent.addToken!.isCancelled, isTrue);
      pending.complete(existing);
      await tester.pumpAndSettle();
      expect(torrent.cancelled, isEmpty);
      expect(torrent.started, isEmpty);
      expect(torrent.taskList.single.state, TorrentTaskState.downloading);
    },
  );

  testWidgets(
    'unsupported engine displays a reason without offering unavailable resume',
    (tester) async {
      final torrent = _TorrentService()
        ..available = const TorrentCapability(
          supported: false,
          ready: false,
          unavailableReason: '当前平台暂不支持磁力播放',
        )
        ..taskList = [_task('one', state: TorrentTaskState.paused)];
      addTearDown(torrent.close);
      await tester.pumpWidget(
        MaterialApp(home: TorrentTasksPage(service: torrent)),
      );
      await tester.pumpAndSettle();
      expect(find.text('当前平台暂不支持磁力播放'), findsOneWidget);
      expect(_button(tester, '继续').onPressed, isNull);
    },
  );

  testWidgets(
    'a saved task file navigates with exact task and file identity without RSS lookup',
    (tester) async {
      final torrent = _TorrentService()
        ..taskList = [
          _task(
            'saved-task',
            state: TorrentTaskState.completed,
            subjectData: rssSubjectToJson(
              _subject()..images['large'] = 'https://covers.test/original.jpg',
            ),
            files: [
              const TorrentFileInfo(
                index: 7,
                name: 'episode-12.5.mkv',
                size: 1000,
                isVideo: true,
              ),
            ],
          ),
        ];
      addTearDown(torrent.close);
      OnlineVideoPlaybackArgs? received;
      final module = createModule(
        register: (c) {
          c.route('/', child: (_, _) => TorrentTasksPage(service: torrent));
          c.route(
            '/video/',
            child: (_, state) {
              received = state.arguments as OnlineVideoPlaybackArgs;
              return const Scaffold(body: Text('saved task playback'));
            },
          );
        },
      );
      await tester.pumpWidget(
        ModularApp(
          module: module,
          child: Builder(
            builder: (context) => MaterialApp.router(
              routerConfig: ModularApp.routerConfigOf(context),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('1 个视频文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('播放该文件'));
      await tester.pumpAndSettle();
      expect(find.text('saved task playback'), findsOneWidget);
      expect(received?.bangumiItem.id, 400602);
      expect(received?.bangumiItem.name, 'Sousou no Frieren');
      expect(
        received?.bangumiItem.images['large'],
        'https://covers.test/original.jpg',
      );
      expect(received?.playbackSource, 'rss');
      expect(received?.torrentTaskId, 'saved-task');
      expect(received?.torrentFileIndex, 7);
      expect(received?.rssReleaseId, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('unbound saved task explains why file playback is disabled', (
    tester,
  ) async {
    final torrent = _TorrentService()
      ..taskList = [
        _task(
          'unbound',
          subjectId: null,
          files: [
            const TorrentFileInfo(
              index: 0,
              name: 'video.mkv',
              size: 1000,
              isVideo: true,
            ),
          ],
        ),
      ];
    addTearDown(torrent.close);
    await tester.pumpWidget(
      MaterialApp(home: TorrentTasksPage(service: torrent)),
    );
    await tester.pumpAndSettle();
    expect(find.text('未关联番剧，无法在应用内播放'), findsOneWidget);
    await tester.tap(find.text('1 个视频文件'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '播放该文件',
            ),
          )
          .onPressed,
      isNull,
    );
  });

  for (final scenario in <(String, Map<String, dynamic>)>[
    ('another subject', {...rssSubjectToJson(_subject()), 'id': 123}),
    ('damaged metadata', {'id': 400602, 'rating': 'invalid'}),
  ]) {
    testWidgets(
      'saved task playback tolerates ${scenario.$1} without changing its bound id',
      (tester) async {
        final torrent = _TorrentService()
          ..taskList = [
            _task(
              'fallback-task',
              subjectData: scenario.$2,
              files: [
                const TorrentFileInfo(
                  index: 2,
                  name: 'video.mkv',
                  size: 1000,
                  isVideo: true,
                ),
              ],
            ),
          ];
        addTearDown(torrent.close);
        OnlineVideoPlaybackArgs? received;
        final module = createModule(
          register: (c) {
            c.route('/', child: (_, _) => TorrentTasksPage(service: torrent));
            c.route(
              '/video/',
              child: (_, state) {
                received = state.arguments as OnlineVideoPlaybackArgs;
                return const Scaffold(body: Text('fallback task playback'));
              },
            );
          },
        );
        await tester.pumpWidget(
          ModularApp(
            module: module,
            child: Builder(
              builder: (context) => MaterialApp.router(
                routerConfig: ModularApp.routerConfigOf(context),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('1 个视频文件'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('播放该文件'));
        await tester.pumpAndSettle();
        expect(find.text('fallback task playback'), findsOneWidget);
        expect(received?.bangumiItem.id, 400602);
        expect(received?.bangumiItem.name, 'fallback-task');
        expect(received?.torrentTaskId, 'fallback-task');
        expect(received?.torrentFileIndex, 2);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  for (final size in [const Size(320, 720), const Size(1280, 900)]) {
    testWidgets(
      'subscription resources fit ${size.width.toInt()}px with a long release title',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final show = _show();
        final rss = _RssService()
          ..subscriptions = [
            RssSubscription(
              id: 'selected',
              subject: _subject(),
              show: show,
              group: show.groups.single,
              createdAt: DateTime(2026),
            ),
          ]
          ..selectedId = 'selected'
          ..releases = [
            RssRelease(
              key: 'long',
              title: '字幕组1080p简体中文磁力资源${'很长的资源名称' * 20}',
              detailUri: Uri.parse('https://mikanani.me/Home/Episode/123'),
              torrentUri: Uri.parse('https://mikanani.me/Download/123.torrent'),
              episodeNumber: 1,
              bangumiId: 400602,
            ),
          ];
        final torrent = _TorrentService();
        addTearDown(rss.dispose);
        addTearDown(torrent.close);
        await tester.pumpWidget(
          MaterialApp(
            home: SubscriptionsPage(
              service: rss,
              torrentService: torrent,
              subject: _subject(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.drag(find.byType(ListView).last, const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'torrent controls and expanded long file names fit ${size.width.toInt()}px',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final torrent = _TorrentService()
          ..taskList = [
            _task(
              '磁力资源名称${'字幕组与视频信息' * 12}',
              files: [
                TorrentFileInfo(
                  index: 0,
                  name: '${'very-long-episode-name-' * 10}.mkv',
                  size: 1000000,
                  isVideo: true,
                ),
              ],
            ),
          ];
        addTearDown(torrent.close);
        await tester.pumpWidget(
          MaterialApp(home: TorrentTasksPage(service: torrent)),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('1 个视频文件'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('1 个视频文件'));
        await tester.pumpAndSettle();
        await tester.drag(find.byType(ListView).first, const Offset(0, -400));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}

IconButton _button(WidgetTester tester, String tooltip) =>
    tester.widget<IconButton>(
      find
          .ancestor(
            of: find.byTooltip(tooltip),
            matching: find.byType(IconButton),
          )
          .first,
    );

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _RssService extends ChangeNotifier implements RssSubscriptionService {
  MikanShow? resolvedShow;
  Future<MikanShow?>? pendingResolve;
  CancelToken? resolveToken;
  Object? initializeFailure;
  List<MikanShow> searchResults = [];
  MikanSubtitleGroup? selectedGroup;
  BangumiItem? subscribedSubject;
  String? refreshedSubscriptionId;
  String? selectedId;
  @override
  List<RssSubscription> subscriptions = [];
  @override
  List<RssRelease> releases = [];
  @override
  bool get isLoading => false;
  @override
  String? get lastError => null;
  @override
  Future<void> initialize() async {
    if (initializeFailure != null) throw initializeFailure!;
  }

  @override
  Future<MikanShow?> resolveSubject(
    BangumiItem subject, {
    CancelToken? cancelToken,
  }) {
    resolveToken = cancelToken;
    return pendingResolve ?? Future.value(resolvedShow);
  }

  @override
  Future<List<MikanShow>> searchShows(
    String keyword, {
    CancelToken? cancelToken,
  }) async => searchResults;
  @override
  Future<MikanShow> getShow(int mikanId, {CancelToken? cancelToken}) async =>
      searchResults.firstWhere((show) => show.id == mikanId);
  @override
  Future<RssSubscription> subscribe(
    BangumiItem subject,
    MikanShow show,
    MikanSubtitleGroup group, {
    CancelToken? cancelToken,
  }) async {
    subscribedSubject = subject;
    selectedGroup = group;
    final subscription = RssSubscription(
      id: 'selected',
      subject: subject,
      show: show,
      group: group,
      createdAt: DateTime(2026),
    );
    subscriptions = [subscription];
    selectedId = subscription.id;
    notifyListeners();
    return subscription;
  }

  @override
  Future<void> refresh({
    String? subscriptionId,
    CancelToken? cancelToken,
  }) async {
    refreshedSubscriptionId = subscriptionId;
  }

  @override
  List<RssRelease> releasesForSubject(
    int bangumiId, {
    double? episodeNumber,
    String? subscriptionId,
  }) => releases.where((release) => release.bangumiId == bangumiId).toList();
  @override
  RssSubscription? subscriptionForSubject(int bangumiId) {
    for (final item in subscriptions) {
      if (item.id == selectedId &&
          item.bangumiId == bangumiId &&
          item.enabled) {
        return item;
      }
    }
    return null;
  }

  @override
  Future<void> selectSubscription(String id) async {
    selectedId = id;
    notifyListeners();
  }

  DateTime? since;
  final viewed = <int>[];
  @override
  DateTime? newSince(int bangumiId) => since;
  @override
  int newReleaseCount(int bangumiId) => 0;
  @override
  Future<void> markViewed(int bangumiId) async => viewed.add(bangumiId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ObservedTask extends TorrentTaskSnapshot {
  _ObservedTask(String id)
    : super(
        id: id,
        title: id,
        source: Uri.parse('magnet:?xt=urn:btih:${'a' * 40}'),
        state: TorrentTaskState.completed,
        totalBytes: 100,
        downloadedBytes: 100,
        progress: 1,
      );

  int titleReads = 0;
  @override
  String get title {
    titleReads++;
    return id;
  }
}

class _TorrentService implements TorrentService {
  final tasksController =
      StreamController<List<TorrentTaskSnapshot>>.broadcast();
  final capabilityController = StreamController<TorrentCapability>.broadcast();
  List<TorrentTaskSnapshot> taskList = [];
  TorrentCapability available = const TorrentCapability(
    supported: true,
    ready: true,
  );
  Future<void>? pauseResult;
  Future<void>? initializeResult;
  Object? initializeFailure;
  int initializeCalls = 0;
  Future<TorrentTaskSnapshot>? addResult;
  CancelToken? addToken;
  final started = <String>[];
  final paused = <String>[];
  final resumed = <String>[];
  final cancelled = <String>[];
  final deleted = <(String, bool)>[];
  @override
  TorrentCapability get capability => available;
  @override
  List<TorrentTaskSnapshot> get tasks => taskList;
  @override
  Stream<List<TorrentTaskSnapshot>> get watchTasks => tasksController.stream;
  @override
  Stream<TorrentCapability> get watchCapability => capabilityController.stream;
  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (initializeFailure != null) throw initializeFailure!;
    await initializeResult;
  }

  @override
  Future<TorrentTaskSnapshot> add(
    Uri source, {
    String? title,
    int? bangumiId,
    int? subjectId,
    double? episodeNumber,
    String? releaseKey,
    Map<String, dynamic>? subjectData,
    CancelToken? cancelToken,
  }) {
    addToken = cancelToken;
    return addResult!;
  }

  @override
  Future<void> startDownload(String taskId, {List<int>? fileIndices}) async {
    started.add(taskId);
  }

  @override
  Future<void> pause(String taskId) async {
    paused.add(taskId);
    await pauseResult;
  }

  @override
  Future<void> resume(String taskId) async {
    resumed.add(taskId);
  }

  @override
  Future<void> cancel(String taskId) async {
    cancelled.add(taskId);
  }

  @override
  Future<void> delete(String taskId, {bool deleteFiles = true}) async {
    deleted.add((taskId, deleteFiles));
  }

  void emit(List<TorrentTaskSnapshot> tasks) {
    taskList = tasks;
    tasksController.add(tasks);
  }

  Future<void> close() async {
    await tasksController.close();
    await capabilityController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BangumiItem _subject() => BangumiItem(
  id: 400602,
  type: 2,
  name: 'Sousou no Frieren',
  nameCn: '葬送的芙莉莲',
  summary: '',
  airDate: '2023-09-29',
  airWeekday: 5,
  rank: 0,
  images: {},
  tags: [],
  alias: [],
  ratingScore: 0,
  votes: 0,
  votesCount: [],
  info: '',
);
MikanShow _show({
  int id = 3141,
  int bangumiId = 400602,
  String title = '葬送的芙莉莲',
}) => MikanShow(
  id: id,
  title: title,
  detailUri: Uri.parse('https://mikanani.me/Home/Bangumi/$id'),
  bangumiId: bangumiId,
  groups: [
    MikanSubtitleGroup(
      id: 370,
      name: '字幕组甲',
      feedUri: Uri.parse(
        'https://mikanani.me/RSS/Bangumi?bangumiId=$id&subgroupid=370',
      ),
    ),
  ],
);
TorrentTaskSnapshot _task(
  String id, {
  TorrentTaskState state = TorrentTaskState.downloading,
  int? subjectId = 400602,
  List<TorrentFileInfo> files = const [],
  Map<String, dynamic>? subjectData,
}) => TorrentTaskSnapshot(
  id: id,
  source: Uri.parse(
    'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
  ),
  title: id,
  state: state,
  bangumiId: subjectId,
  progress: 0.5,
  totalBytes: 1000,
  downloadedBytes: 500,
  files: files,
  subjectData: subjectData,
);
