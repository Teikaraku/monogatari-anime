import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/kazumi_menu.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/bean/widget/split_list_row.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/subscriptions/rss_widgets.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/download/background_download_service.dart';
import 'package:kazumi/services/rss/rss_subscription_service.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:kazumi/services/torrent/torrent_models.dart';
import 'package:kazumi/utils/format.dart';
import 'package:kazumi/utils/theme.dart';

/// Subscriptions are application-owned; this route owns only its UI requests.
class SubscriptionsPage extends StatefulWidget {
  const SubscriptionsPage({
    super.key,
    required this.service,
    required this.torrentService,
    this.subject,
  });

  final RssSubscriptionService service;
  final TorrentService torrentService;
  final BangumiItem? subject;

  @override
  State<SubscriptionsPage> createState() => _SubscriptionsPageState();
}

class _SubscriptionsPageState extends State<SubscriptionsPage> {
  CancelToken? _request;
  int _revision = 0;
  String? _busy;
  String? _error;
  MikanShow? _show;
  bool _initialized = false;

  /// Releases published after this are marked new on this visit.
  DateTime? _newSince;
  StreamSubscription<TorrentCapability>? _capabilitySubscription;
  Future<void>? _torrentInitialization;
  TorrentService? _torrentInitializationService;
  String? _torrentError;

  @override
  void initState() {
    super.initState();
    _attachCapability();
    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(covariant SubscriptionsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.torrentService != widget.torrentService) {
      _attachCapability();
      _torrentError = null;
      unawaited(_initializeTorrent());
    }
    if (oldWidget.service != widget.service ||
        oldWidget.subject?.id != widget.subject?.id) {
      _cancel();
      _initialized = false;
      _show = null;
      _error = null;
      unawaited(_initialize());
    }
  }

  @override
  void dispose() {
    _revision++;
    _request?.cancel('订阅页面已关闭');
    unawaited(_capabilitySubscription?.cancel());
    super.dispose();
  }

  Future<void> _initialize() async {
    // BT task restoration is independent of RSS browsing and show matching.
    unawaited(_initializeTorrent());
    await _run('正在加载订阅', (token) async {
      await widget.service.initialize();
      if (token.isCancelled) return;
      _initialized = true;
      final subject = widget.subject;
      if (subject != null) {
        _newSince = widget.service.newSince(subject.id);
        unawaited(
          widget.service.markViewed(subject.id).catchError((Object error) {
            if (mounted && !token.isCancelled) {
              setState(() => _error = _readableError(error));
            }
          }),
        );
        final subscriptions = widget.service.subscriptions.where(
          (item) => item.bangumiId == subject.id,
        );
        if (subscriptions.isNotEmpty) {
          _show =
              widget.service.subscriptionForSubject(subject.id)?.show ??
              subscriptions.first.show;
        } else {
          final show = await widget.service.resolveSubject(
            subject,
            cancelToken: token,
          );
          if (!token.isCancelled && mounted) _show = show;
        }
      }
    });
  }

  Future<void> _initializeTorrent() {
    final service = widget.torrentService;
    if (identical(_torrentInitializationService, service) &&
        _torrentInitialization != null) {
      return _torrentInitialization!;
    }
    if (!service.capability.supported || service.capability.ready) {
      return Future.value();
    }
    _torrentInitializationService = service;
    if (mounted) setState(() => _torrentError = null);
    late final Future<void> work;
    work = Future<void>.sync(service.initialize)
        .catchError((Object _) {
          if (mounted &&
              identical(widget.torrentService, service) &&
              identical(_torrentInitialization, work)) {
            setState(() => _torrentError = '磁力引擎启动失败，请重试');
          }
        })
        .whenComplete(() {
          if (identical(_torrentInitialization, work)) {
            _torrentInitialization = null;
            if (mounted && identical(widget.torrentService, service)) {
              setState(() {});
            }
          }
        });
    return _torrentInitialization = work;
  }

  void _attachCapability() {
    unawaited(_capabilitySubscription?.cancel());
    final service = widget.torrentService;
    _capabilitySubscription = service.watchCapability.listen((_) {
      if (mounted && identical(service, widget.torrentService)) setState(() {});
    }, onError: (Object _) {});
  }

  Future<void> _run(
    String label,
    Future<void> Function(CancelToken) operation,
  ) async {
    _request?.cancel('新的订阅操作');
    final token = _request = CancelToken();
    final revision = ++_revision;
    setState(() {
      _busy = label;
      _error = null;
    });
    try {
      await operation(token);
    } catch (error) {
      if (mounted && revision == _revision && !token.isCancelled) {
        setState(() => _error = _readableError(error));
      }
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = null);
    }
  }

  void _cancel() {
    _revision++;
    _request?.cancel('用户取消');
    _request = null;
    if (mounted) setState(() => _busy = null);
  }

  String _readableError(Object error) {
    if (error is RssException) return error.message;
    if (error is DioException) return '访问订阅服务失败，请检查网络后重试';
    // Validation errors explain a mismatched season or unsupported feed.
    if (error is FormatException) return error.message;
    if (error is StateError) return error.message;
    return '操作失败，请重试';
  }

  Future<void> _addSubject() async {
    final value = await _input(
      title: '添加番组订阅',
      label: 'Bangumi 条目链接或 ID',
      hint: 'https://bangumi.tv/subject/123456',
    );
    if (value == null || !mounted) return;
    final id = _subjectId(value);
    if (id == null) {
      setState(() => _error = '请输入有效的 Bangumi 条目链接或 ID');
      return;
    }
    await _run('正在读取番组', (token) async {
      final result = await BangumiApi.getBangumiSubjectByID(id);
      if (token.isCancelled || !mounted) return;
      if (result == null) throw StateError('无法读取这个番组，请检查条目 ID');
      await context.pushNamed('/subscriptions/', arguments: result.$1);
    });
  }

  Future<void> _searchShow() async {
    final subject = widget.subject;
    if (subject == null) return;
    final keyword = await _input(
      title: '搜索蜜柑番组',
      label: '番组名称',
      initial: subject.nameCn.isNotEmpty ? subject.nameCn : subject.name,
    );
    if (keyword == null || !mounted) return;
    List<MikanShow>? results;
    await _run('正在搜索蜜柑', (token) async {
      final shows = await widget.service.searchShows(
        keyword,
        cancelToken: token,
      );
      if (token.isCancelled || !mounted) return;
      results = shows;
    });
    if (results == null || !mounted || widget.subject?.id != subject.id) return;
    final selected = await showAdaptiveBottomSheet<MikanShow>(
      context: context,
      builder: (context) => _ShowSelection(shows: results!),
    );
    if (selected == null || !mounted || widget.subject?.id != subject.id) {
      return;
    }
    await _run('正在确认所属季度', (token) async {
      final show = await widget.service.getShow(
        selected.id,
        cancelToken: token,
      );
      if (token.isCancelled) return;
      if (show.bangumiId != subject.id) {
        throw StateError('这个蜜柑番组与当前 Bangumi 条目不一致，请选择对应季度');
      }
      _show = show;
    });
  }

  Future<void> _chooseGroup() async {
    final subject = widget.subject;
    final show = _show;
    if (subject == null || show == null) return;
    final group = await showAdaptiveBottomSheet<MikanSubtitleGroup>(
      context: context,
      builder: (context) => _GroupSelection(
        show: show,
        subscribed: {
          for (final item in widget.service.subscriptions)
            if (item.bangumiId == subject.id) item.subtitleGroupId,
        },
      ),
    );
    if (group == null || !mounted) return;
    await _run('正在订阅 ${group.name}', (token) async {
      final subscription = await widget.service.subscribe(
        subject,
        show,
        group,
        cancelToken: token,
      );
      if (!token.isCancelled) {
        await widget.service.refresh(
          subscriptionId: subscription.id,
          cancelToken: token,
        );
      }
    });
  }

  Future<void> _addFeed() async {
    final subject = widget.subject;
    if (subject == null) return;
    final value = await _input(
      title: '添加字幕组 RSS',
      label: '蜜柑字幕组 RSS 地址',
      hint: '粘贴这个番组对应字幕组的 RSS 链接',
    );
    if (value == null || !mounted) return;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      setState(() => _error = '请输入有效的 HTTPS RSS 地址');
      return;
    }
    await _run('正在验证 RSS 地址', (token) async {
      final preview = await widget.service.previewFeed(uri, cancelToken: token);
      if (token.isCancelled || !mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认订阅'),
          content: Text(
            '${preview.title}\n找到 ${preview.releases.length} 条资源，将验证其番组和字幕组。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('订阅'),
            ),
          ],
        ),
      );
      if (accepted != true || token.isCancelled) return;
      await widget.service.subscribeFeed(subject, uri, cancelToken: token);
      if (!token.isCancelled) await _refreshSubject(token);
    });
  }

  Future<String?> _input({
    required String title,
    required String label,
    String? hint,
    String initial = '',
  }) async {
    return showDialog<String>(
      context: context,
      builder: (context) => _InputDialog(
        title: title,
        label: label,
        hint: hint,
        initial: initial,
      ),
    );
  }

  Future<void> _remove(RssSubscription subscription) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除订阅'),
        content: Text('不再接收 ${subscription.subtitleGroupName} 的更新，已下载的文件会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除订阅'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await _run('正在删除订阅', (_) => widget.service.remove(subscription.id));
    }
  }

  Future<void> _play(RssRelease release) async {
    final subject = widget.subject;
    if (subject == null) return;
    double? episode = release.episodeNumber;
    if (release.isBatch) {
      episode = await showAdaptiveBottomSheet<double>(
        context: context,
        builder: (context) =>
            _EpisodeNumberSheet(numbers: release.episodeNumbers),
      );
      if (episode == null || !mounted) return;
    }
    await BackgroundDownloadService().resumeForUser();
    if (!mounted) return;
    context.pushNamed(
      '/video/',
      arguments: OnlineVideoPlaybackArgs(
        bangumiItem: subject,
        playbackSource: 'rss',
        rssReleaseId: release.key,
        rssEpisodeNumber: episode,
      ),
    );
  }

  Future<void> _download(RssRelease release) async {
    await _run('正在获取种子与文件信息', (token) async {
      await BackgroundDownloadService().resumeForUser();
      if (token.isCancelled || !mounted) return;
      final task = await widget.torrentService.add(
        release.sourceUri,
        title: release.title,
        bangumiId: widget.subject?.id,
        releaseKey: release.key,
        episodeNumber: release.episodeNumber,
        subjectData: widget.subject == null
            ? null
            : rssSubjectToJson(widget.subject!),
        cancelToken: token,
      );
      // add() may reuse an existing download or playback task. Cancelling this
      // page's preparation must never pause another consumer's task. Metadata
      // is cancellable above; accepted downloads are controlled in the task UI.
      if (token.isCancelled) return;
      await widget.torrentService.startDownload(task.id);
      if (!token.isCancelled && mounted) {
        unawaited(
          context.pushNamed('/torrent-tasks/', arguments: widget.subject?.id),
        );
      }
    });
  }

  Future<void> _refreshSubject(CancelToken token) async {
    final subject = widget.subject;
    if (subject == null) {
      await widget.service.refresh(cancelToken: token);
      return;
    }
    final subscriptions = widget.service.subscriptions
        .where((item) => item.bangumiId == subject.id && item.enabled)
        .toList();
    for (final subscription in subscriptions) {
      if (token.isCancelled) return;
      await widget.service.refresh(
        subscriptionId: subscription.id,
        cancelToken: token,
      );
    }
  }

  Future<void> _select(RssSubscription subscription) => _run(
    '正在切换字幕组',
    (_) => widget.service.selectSubscription(subscription.id),
  );

  Future<void> _setEnabled(RssSubscription subscription, bool enabled) => _run(
    enabled ? '正在恢复更新' : '正在暂停更新',
    (_) => widget.service.setEnabled(subscription.id, enabled),
  );

  Future<void> _refreshOne(RssSubscription subscription) => _run(
    '正在刷新 ${subscription.subtitleGroupName}',
    (token) => widget.service.refresh(
      subscriptionId: subscription.id,
      cancelToken: token,
    ),
  );

  void _openTasks() => unawaited(
    context.pushNamed('/torrent-tasks/', arguments: widget.subject?.id),
  );

  bool get _torrentReady {
    final capability = widget.torrentService.capability;
    return capability.supported && capability.ready;
  }

  @override
  Widget build(BuildContext context) {
    final subject = widget.subject;
    final idle = _busy == null;
    return SettingsDetailScaffold(
      title: Text(subject == null ? 'RSS 订阅' : 'RSS 资源'),
      actions: [
        IconButton(
          tooltip: '刷新订阅',
          onPressed: idle ? () => _run('正在刷新订阅', _refreshSubject) : null,
          icon: const Icon(Icons.refresh_rounded),
        ),
        if (subject == null) ...[
          IconButton(
            tooltip: '磁力任务',
            onPressed: _openTasks,
            icon: const Icon(Icons.hub_rounded),
          ),
          IconButton(
            tooltip: '添加订阅',
            onPressed: idle ? _addSubject : null,
            icon: const Icon(Icons.add_rounded),
          ),
        ] else
          KazumiMenuButton(
            menuChildren: [
              KazumiMenuItem(
                label: '重新匹配番组',
                leadingIcon: const Icon(Icons.search_rounded),
                onPressed: idle ? _searchShow : null,
              ),
              KazumiMenuItem(
                label: '添加 RSS 地址',
                leadingIcon: const Icon(Icons.link_rounded),
                onPressed: idle ? _addFeed : null,
              ),
              KazumiMenuItem(
                label: '磁力任务',
                leadingIcon: const Icon(Icons.hub_rounded),
                onPressed: _openTasks,
              ),
            ],
            builder: (context, toggle) => IconButton(
              tooltip: '更多',
              onPressed: toggle,
              icon: const Icon(Icons.more_horiz_rounded),
            ),
          ),
      ],
      body: MonoGroupedScope(
        grouped: true,
        child: AnimatedBuilder(
          animation: widget.service,
          builder: (context, _) {
            final subscriptions = widget.service.subscriptions
                .where(
                  (item) => subject == null || item.bangumiId == subject.id,
                )
                .toList();
            final banners = _banners();
            if (!_initialized && _busy != null) {
              return _Column(
                children: [
                  ...banners,
                  const SizedBox(
                    height: 240,
                    child: Center(child: LoadingIndicator()),
                  ),
                ],
              );
            }
            if (subject == null) {
              if (subscriptions.isEmpty) {
                return _Column(
                  scrollable: false,
                  children: [
                    ...banners,
                    Expanded(
                      child: GeneralEmptyState(
                        icon: Icons.rss_feed_rounded,
                        title: '还没有 RSS 订阅',
                        actions: [
                          FilledButton.icon(
                            onPressed: idle ? _addSubject : null,
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('添加订阅'),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              }
              return _Column(children: [...banners, _overview(subscriptions)]);
            }
            return _Column(
              children: [
                ...banners,
                _SubjectHeader(subject: subject, show: _show),
                const SizedBox(height: 24),
                ..._groupSection(subscriptions),
                const SizedBox(height: 24),
                ..._releaseSection(
                  subscriptions,
                  widget.service.releasesForSubject(subject.id),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _banners() {
    final capability = widget.torrentService.capability;
    final error = _error ?? widget.service.lastError;
    return [
      if (_busy != null)
        RssBanner(
          message: _busy!,
          tone: RssBannerTone.progress,
          actionLabel: '取消',
          onAction: _cancel,
        ),
      if (error != null)
        RssBanner(
          message: error,
          tone: RssBannerTone.error,
          actionLabel: '重试',
          onAction: _busy == null ? _initialize : null,
        ),
      if (_torrentError != null)
        RssBanner(
          message: _torrentError!,
          tone: RssBannerTone.error,
          actionLabel: '重试',
          onAction: _torrentInitialization == null
              ? () => unawaited(_initializeTorrent())
              : null,
        )
      else if (widget.subject != null &&
          (!capability.supported || !capability.ready))
        RssBanner(
          message:
              capability.unavailableReason ??
              (_torrentInitialization != null ? '正在准备磁力播放' : '磁力引擎暂不可用'),
          tone: RssBannerTone.info,
        ),
    ];
  }

  /// One row per show; the show's page manages its subtitle groups.
  Widget _overview(List<RssSubscription> subscriptions) {
    final byShow = <int, List<RssSubscription>>{};
    for (final subscription in subscriptions) {
      byShow.putIfAbsent(subscription.bangumiId, () => []).add(subscription);
    }
    final palette = MonoPalette.of(context);
    final colors = Theme.of(context).colorScheme;
    return RssGroup(
      dividerIndent: 16 + 44 + 12,
      children: [
        for (final group in byShow.values)
          Builder(
            builder: (context) {
              final first = group.first;
              final failed = group.any((item) => item.lastError != null);
              final paused = group.every((item) => !item.enabled);
              final refreshed = group
                  .map((item) => item.lastRefreshedAt)
                  .whereType<DateTime>()
                  .fold<DateTime?>(
                    null,
                    (a, b) => a == null || b.isAfter(a) ? b : a,
                  );
              final fresh = widget.service.newReleaseCount(first.bangumiId);
              return RssRow(
                leading: _Cover(subject: first.subject, width: 44),
                title: first.title,
                titleWeight: FontWeight.w500,
                subtitle: group
                    .map((item) => item.subtitleGroupName)
                    .join(' · '),
                detail: failed
                    ? '更新失败'
                    : paused
                    ? '已暂停更新'
                    : fresh > 0
                    ? '$fresh 个新资源'
                    : refreshed == null
                    ? null
                    : '${rssShortDate(refreshed, withTime: true)} 刷新',
                detailColor: failed
                    ? colors.error
                    : !paused && fresh > 0
                    ? colors.primary
                    : null,
                trailing: Icon(
                  Icons.chevron_right_rounded,
                  color: palette.tertiaryLabel,
                ),
                onTap: () => context.pushNamed(
                  '/subscriptions/',
                  arguments: first.subject,
                ),
              );
            },
          ),
      ],
    );
  }

  List<Widget> _groupSection(List<RssSubscription> subscriptions) {
    final idle = _busy == null;
    if (_show == null && subscriptions.isEmpty) {
      if (!idle) return const [];
      return [
        const RssCaption('未匹配到蜜柑番组'),
        RssGroup(
          dividerIndent: 16 + 24 + 12,
          children: [
            RssActionRow(
              icon: Icons.search_rounded,
              label: '搜索番组',
              onTap: _searchShow,
            ),
            RssActionRow(
              icon: Icons.link_rounded,
              label: '添加 RSS 地址',
              onTap: _addFeed,
            ),
          ],
        ),
      ];
    }
    final selectedId = widget.service
        .subscriptionForSubject(widget.subject!.id)
        ?.id;
    return [
      const RssCaption('字幕组'),
      RssGroup(
        dividerIndent: 16 + 24 + 12,
        children: [
          for (final subscription in subscriptions)
            _GroupRow(
              subscription: subscription,
              selected: subscription.id == selectedId,
              enabled: idle,
              onSelect: () => _select(subscription),
              onRefresh: () => _refreshOne(subscription),
              onToggle: () => _setEnabled(subscription, !subscription.enabled),
              onRemove: () => _remove(subscription),
            ),
          if (_show != null)
            RssActionRow(
              icon: Icons.add_rounded,
              label: subscriptions.isEmpty ? '选择字幕组' : '添加字幕组',
              onTap: idle ? _chooseGroup : null,
            )
          else
            RssActionRow(
              icon: Icons.link_rounded,
              label: '添加 RSS 地址',
              onTap: idle ? _addFeed : null,
            ),
        ],
      ),
    ];
  }

  List<Widget> _releaseSection(
    List<RssSubscription> subscriptions,
    List<RssRelease> releases,
  ) {
    final palette = MonoPalette.of(context);
    return [
      RssCaption(
        '资源',
        trailing: releases.isEmpty ? null : '${releases.length} 个',
      ),
      if (releases.isEmpty)
        RssGroup(
          children: [
            RssRow(
              title: subscriptions.isEmpty
                  ? '订阅字幕组后显示资源'
                  : widget.service.subscriptionForSubject(widget.subject!.id) ==
                        null
                  ? '选择一个字幕组后显示资源'
                  : '暂无资源',
              titleColor: palette.secondaryLabel,
            ),
          ],
        )
      else
        RssGroup(
          dividerIndent: 16 + 44 + 12,
          children: [
            for (final release in releases)
              _ReleaseRow(
                release: release,
                names: [widget.subject!.name, widget.subject!.nameCn],
                isNew:
                    _newSince != null &&
                    (release.publishedAt?.isAfter(_newSince!) ?? false),
                enabled: _busy == null && _torrentReady,
                onPlay: () => _play(release),
                onDownload: () => _download(release),
              ),
          ],
        ),
    ];
  }
}

/// The page body: a centred, readable column.
class _Column extends StatelessWidget {
  const _Column({required this.children, this.scrollable = true});

  final List<Widget> children;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final bottom = 32 + MediaQuery.paddingOf(context).bottom;
    if (!scrollable) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: settingsReadableWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      );
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 4, 16, bottom),
      children: [
        for (final child in children)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: settingsReadableWidth,
              ),
              child: child,
            ),
          ),
      ],
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.subject, required this.width});

  final BangumiItem subject;
  final double width;

  @override
  Widget build(BuildContext context) {
    final src = subject.images['large'] ?? subject.images['common'] ?? '';
    return NetworkImgLayer(
      src: src,
      width: width,
      height: width * 4 / 3,
      borderRadius: BorderRadius.circular(width >= 56 ? 8 : 6),
    );
  }
}

class _SubjectHeader extends StatelessWidget {
  const _SubjectHeader({required this.subject, required this.show});

  final BangumiItem subject;
  final MikanShow? show;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = MonoPalette.of(context);
    final name = subject.nameCn.isNotEmpty ? subject.nameCn : subject.name;
    final original = subject.nameCn.isNotEmpty && subject.name != subject.nameCn
        ? subject.name
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          _Cover(subject: subject, width: 60),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontSize: 18,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (original != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    original,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: palette.secondaryLabel,
                    ),
                  ),
                ],
                if (show != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        size: 14,
                        color: palette.success,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '蜜柑 · ${show!.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: palette.secondaryLabel,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A subscribed subtitle group. Tapping picks it for playback; the menu
/// refreshes, pauses or removes it.
class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.subscription,
    required this.selected,
    required this.enabled,
    required this.onSelect,
    required this.onRefresh,
    required this.onToggle,
    required this.onRemove,
  });

  final RssSubscription subscription;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelect;
  final VoidCallback onRefresh;
  final VoidCallback onToggle;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = MonoPalette.of(context);
    final active = subscription.enabled;
    final error = subscription.lastError;
    final refreshed = subscription.lastRefreshedAt;
    return RssRow(
      selected: selected,
      leading: SizedBox(
        width: 24,
        child: Icon(
          !active
              ? Icons.pause_circle_outline_rounded
              : selected
              ? Icons.check_circle_rounded
              : Icons.circle_outlined,
          size: 22,
          color: selected && active ? colors.primary : palette.tertiaryLabel,
        ),
      ),
      title: subscription.subtitleGroupName,
      titleWeight: selected ? FontWeight.w600 : FontWeight.w400,
      subtitle:
          error ??
          (!active
              ? '已暂停更新'
              : refreshed == null
              ? null
              : '${rssShortDate(refreshed, withTime: true)} 刷新'),
      subtitleColor: error != null ? colors.error : null,
      onTap: enabled && active && !selected ? onSelect : null,
      trailing: KazumiMenuButton(
        enabled: enabled,
        menuChildren: [
          KazumiMenuItem(
            label: '刷新',
            leadingIcon: const Icon(Icons.refresh_rounded),
            onPressed: onRefresh,
          ),
          KazumiMenuItem(
            label: active ? '暂停更新' : '恢复更新',
            leadingIcon: Icon(
              active
                  ? Icons.pause_circle_outline_rounded
                  : Icons.play_circle_outline_rounded,
            ),
            onPressed: onToggle,
          ),
          KazumiMenuItem(
            label: '删除订阅',
            leadingIcon: const Icon(Icons.delete_outline_rounded),
            destructive: true,
            onPressed: onRemove,
          ),
        ],
        builder: (context, toggle) =>
            RssMoreButton(tooltip: '字幕组选项', onPressed: toggle),
      ),
    );
  }
}

String _episodeLabel(double number) =>
    number == number.truncateToDouble() ? '${number.toInt()}' : '$number';

class _ReleaseRow extends StatelessWidget {
  const _ReleaseRow({
    required this.release,
    required this.names,
    this.isNew = false,
    required this.enabled,
    required this.onPlay,
    required this.onDownload,
  });

  final RssRelease release;

  /// Names of the show; bracketed tags repeating them are left out.
  final List<String> names;
  final bool enabled;
  final VoidCallback onPlay;
  final VoidCallback onDownload;

  /// Published since the show was last opened.
  final bool isNew;

  bool get _canPlay =>
      release.episodeNumber != null ||
      release.isSpecial ||
      (release.isBatch && release.episodeNumbers.isNotEmpty);

  /// The bracketed tags of the title other than the group, the show, the
  /// episode and the quality already shown: WebRip · HEVC · 简繁内封.
  String get _tags {
    final skip = {
      release.group.toLowerCase(),
      release.quality.toLowerCase(),
      for (final name in names) name.toLowerCase(),
    }..remove('');
    final episode = RegExp(
      r'^[\d.\s~&+-]+(?:\s*(?:合集|全集|end|v\d))?$',
      caseSensitive: false,
    );
    return [
      for (final match in RegExp(
        r'[\[【]([^\]】]+)[\]】]',
      ).allMatches(release.title))
        if (match[1]!.trim() case final tag
            when tag.isNotEmpty &&
                !skip.contains(tag.toLowerCase()) &&
                !episode.hasMatch(tag))
          tag,
    ].join(' · ');
  }

  (String badge, String title) get _labels {
    final number = release.episodeNumber;
    if (release.isBatch) {
      final numbers = [...release.episodeNumbers]..sort();
      return (
        '合集',
        numbers.isEmpty
            ? '合集'
            : '第 ${_episodeLabel(numbers.first)}–${_episodeLabel(numbers.last)} 话',
      );
    }
    if (release.isSpecial) {
      final key = (release.specialKey ?? 'sp').toUpperCase();
      return (key.length > 3 ? 'SP' : key, number == null ? '特别篇' : '特别篇 $key');
    }
    if (number != null) {
      final label = _episodeLabel(number);
      return (label.length == 1 ? '0$label' : label, '第 $label 话');
    }
    return ('?', '未识别话数');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = MonoPalette.of(context);
    final (badge, title) = _labels;
    final meta = [
      if (release.quality.isNotEmpty) release.quality,
      if (release.sizeBytes != null) formatBytes(release.sizeBytes!),
      if (release.publishedAt != null) rssShortDate(release.publishedAt!),
    ].join(' · ');
    return Tooltip(
      message: release.title,
      waitDuration: const Duration(milliseconds: 600),
      excludeFromSemantics: true,
      child: RssRow(
        leading: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: palette.fill,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            badge,
            maxLines: 1,
            style: TextStyle(
              fontSize: badge.length > 2 ? 13 : 17,
              fontWeight: FontWeight.w700,
              color: colors.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        title: title,
        titleWeight: FontWeight.w500,
        titleMaxLines: 1,
        titleBadge: isNew ? const RssNewBadge() : null,
        subtitle: meta,
        detail: _tags.isEmpty ? release.title : _tags,
        detailMaxLines: 1,
        onTap: enabled && _canPlay ? onPlay : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '下载',
              onPressed: enabled ? onDownload : null,
              color: palette.secondaryLabel,
              icon: const Icon(Icons.download_rounded),
            ),
            if (_canPlay)
              IconButton.filled(
                tooltip: '播放',
                onPressed: enabled ? onPlay : null,
                style: IconButton.styleFrom(
                  backgroundColor: colors.primary.withValues(alpha: 0.12),
                  foregroundColor: colors.primary,
                ),
                icon: const Icon(Icons.play_arrow_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({
    required this.title,
    required this.child,
    this.description,
  });

  final String title;
  final String? description;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      MaterialBottomSheetHeader(
        title: title,
        description: description,
        onClose: () => Navigator.of(context).pop(),
      ),
      Flexible(child: child),
    ],
  );
}

class _SheetList extends StatelessWidget {
  const _SheetList({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(
      16,
      0,
      16,
      16 + MediaQuery.paddingOf(context).bottom,
    ),
    child: RssGroup(children: children),
  );
}

class _ShowSelection extends StatelessWidget {
  const _ShowSelection({required this.shows});
  final List<MikanShow> shows;

  @override
  Widget build(BuildContext context) {
    final palette = MonoPalette.of(context);
    return _SheetFrame(
      title: '选择番组',
      child: shows.isEmpty
          ? const Padding(
              padding: EdgeInsets.only(bottom: 24),
              child: GeneralEmptyState(
                icon: Icons.search_off_rounded,
                title: '没有找到番组',
                compact: true,
              ),
            )
          : _SheetList(
              children: [
                for (final show in shows)
                  RssRow(
                    title: show.title,
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      color: palette.tertiaryLabel,
                    ),
                    onTap: () => Navigator.pop(context, show),
                  ),
              ],
            ),
    );
  }
}

class _GroupSelection extends StatelessWidget {
  const _GroupSelection({required this.show, required this.subscribed});
  final MikanShow show;

  /// Ids of the subtitle groups already subscribed for this show.
  final Set<int> subscribed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = MonoPalette.of(context);
    return _SheetFrame(
      title: '选择字幕组',
      description: show.title,
      child: show.groups.isEmpty
          ? const Padding(
              padding: EdgeInsets.only(bottom: 24),
              child: GeneralEmptyState(
                icon: Icons.group_off_outlined,
                title: '暂无字幕组',
                compact: true,
              ),
            )
          : _SheetList(
              children: [
                for (final group in show.groups)
                  subscribed.contains(group.id)
                      ? RssRow(
                          title: group.name,
                          titleColor: palette.secondaryLabel,
                          trailing: Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Text(
                              '已订阅',
                              style: TextStyle(
                                fontSize: 14,
                                color: palette.secondaryLabel,
                              ),
                            ),
                          ),
                        )
                      : RssRow(
                          title: group.name,
                          trailing: Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Icon(
                              Icons.add_rounded,
                              color: colors.primary,
                            ),
                          ),
                          onTap: () => Navigator.pop(context, group),
                        ),
              ],
            ),
    );
  }
}

/// Picks one episode of a batch release.
class _EpisodeNumberSheet extends StatelessWidget {
  const _EpisodeNumberSheet({required this.numbers});

  final List<double> numbers;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = MonoPalette.of(context);
    return _SheetFrame(
      title: '选择话数',
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 10.0;
          final width = constraints.maxWidth - 40;
          final columns = ((width + gap) / (64 + gap)).floor().clamp(4, 8);
          return GridView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.fromLTRB(
              20,
              4,
              20,
              16 + MediaQuery.paddingOf(context).bottom,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: gap,
              crossAxisSpacing: gap,
              mainAxisExtent: 48,
            ),
            itemCount: numbers.length,
            itemBuilder: (context, index) {
              final number = numbers[index];
              return Material(
                color: palette.sheetGroup,
                borderRadius: BorderRadius.circular(10),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => Navigator.pop(context, number),
                  child: Center(
                    child: Text(
                      _episodeLabel(number),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

int? _subjectId(String value) {
  final direct = int.tryParse(value);
  if (direct != null && direct > 0) return direct;
  final uri = Uri.tryParse(value);
  if (uri == null || !['bangumi.tv', 'bgm.tv', 'chii.in'].contains(uri.host)) {
    return null;
  }
  if (uri.pathSegments.length != 2 || uri.pathSegments.first != 'subject') {
    return null;
  }
  final id = int.tryParse(uri.pathSegments.last);
  return id != null && id > 0 ? id : null;
}

class _InputDialog extends StatefulWidget {
  const _InputDialog({
    required this.title,
    required this.label,
    this.hint,
    required this.initial,
  });
  final String title;
  final String label;
  final String? hint;
  final String initial;
  @override
  State<_InputDialog> createState() => _InputDialogState();
}

class _InputDialogState extends State<_InputDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  void _submit() {
    final value = _controller.text.trim();
    if (value.isNotEmpty) Navigator.pop(context, value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 480,
      child: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
        ),
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('继续')),
    ],
  );
}
