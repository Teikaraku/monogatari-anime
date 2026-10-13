import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/download/background_download_service.dart';
import 'package:kazumi/services/rss/rss_subscription_service.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:kazumi/services/torrent/torrent_models.dart';
import 'package:kazumi/utils/format.dart';

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
      builder: (context) => _GroupSelection(show: show),
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
        content: Text(
          '取消 ${subscription.title} · ${subscription.subtitleGroupName} 的更新订阅？已有磁力任务和文件会保留。',
        ),
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
        builder: (context) => SizedBox(
          height: 400,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '选择话数',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final number in release.episodeNumbers)
                      ListTile(
                        title: Text('第 ${_episodeLabel(number)} 话'),
                        trailing: const Icon(Icons.play_arrow),
                        onTap: () => Navigator.pop(context, number),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
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

  @override
  Widget build(BuildContext context) {
    final subject = widget.subject;
    return Scaffold(
      appBar: SysAppBar(
        title: Text(subject == null ? 'RSS 订阅' : 'RSS 资源与订阅'),
        actions: [
          IconButton(
            tooltip: '刷新订阅',
            onPressed: _busy == null
                ? () => _run('正在刷新订阅', _refreshSubject)
                : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
          if (subject == null)
            IconButton(
              tooltip: '添加订阅',
              onPressed: _busy == null ? _addSubject : null,
              icon: const Icon(Icons.add_rounded),
            ),
        ],
      ),
      body: AnimatedBuilder(
        animation: widget.service,
        builder: (context, _) {
          final subscriptions = widget.service.subscriptions
              .where((item) => subject == null || item.bangumiId == subject.id)
              .toList();
          final releases = subject == null
              ? const <RssRelease>[]
              : widget.service.releasesForSubject(subject.id);
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Column(
                children: [
                  if (_busy != null)
                    _LoadingRow(label: _busy!, onCancel: _cancel),
                  if (_error != null || widget.service.lastError != null)
                    _ErrorRow(
                      message: _error ?? widget.service.lastError!,
                      onRetry: _busy == null ? _initialize : null,
                    ),
                  if (_torrentError != null)
                    _ErrorRow(
                      message: _torrentError!,
                      onRetry: _torrentInitialization == null
                          ? () => unawaited(_initializeTorrent())
                          : null,
                    ),
                  Expanded(
                    child: !_initialized && _busy != null
                        ? const Center(child: CircularProgressIndicator())
                        : subject == null
                        ? _subscriptionList(subscriptions)
                        : _subjectResources(subject, subscriptions, releases),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _subscriptionList(List<RssSubscription> subscriptions) {
    if (subscriptions.isEmpty) {
      return GeneralEmptyState(
        icon: Icons.rss_feed_rounded,
        title: '还没有 RSS 订阅',
        actions: [
          FilledButton.icon(
            onPressed: _busy == null ? _addSubject : null,
            icon: const Icon(Icons.add),
            label: const Text('添加番组订阅'),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: subscriptions.map(_subscriptionCard).toList(),
    );
  }

  Widget _subjectResources(
    BangumiItem subject,
    List<RssSubscription> subscriptions,
    List<RssRelease> releases,
  ) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          subject.nameCn.isNotEmpty ? subject.nameCn : subject.name,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        if (_show != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _show!.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text('蜜柑番组已与当前季度确认匹配'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _busy == null ? _chooseGroup : null,
                        icon: const Icon(Icons.group_outlined),
                        label: Text(
                          subscriptions.isEmpty ? '选择字幕组并订阅' : '添加字幕组',
                        ),
                      ),
                      TextButton(
                        onPressed: _busy == null ? _searchShow : null,
                        child: const Text('重新选择番组'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          )
        else if (_busy == null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('未找到与当前季度确认匹配的蜜柑番组'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _searchShow,
                        icon: const Icon(Icons.search),
                        label: const Text('搜索番组'),
                      ),
                      TextButton(
                        onPressed: _addFeed,
                        child: const Text('添加 RSS 地址'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        for (final subscription in subscriptions)
          _subscriptionCard(subscription),
        if (_show != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy == null ? _addFeed : null,
              icon: const Icon(Icons.link),
              label: const Text('添加字幕组 RSS 地址'),
            ),
          ),
        const SizedBox(height: 16),
        Text('更新资源', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (releases.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              subscriptions.isEmpty
                  ? '选择字幕组并订阅后，这里会显示对应的播放资源'
                  : '还没有本字幕组的资源，可刷新订阅后重试',
            ),
          ),
        for (final release in releases) _releaseCard(release),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _subscriptionCard(RssSubscription subscription) {
    final selected =
        widget.service.subscriptionForSubject(subscription.bangumiId)?.id ==
        subscription.id;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(subscription.title),
              subtitle: Text(subscription.subtitleGroupName),
              onTap: widget.subject == null
                  ? () => context.pushNamed(
                      '/subscriptions/',
                      arguments: subscription.subject,
                    )
                  : null,
              trailing: Switch(
                value: subscription.enabled,
                onChanged: _busy == null
                    ? (enabled) => _run(
                        '正在更新订阅',
                        (_) =>
                            widget.service.setEnabled(subscription.id, enabled),
                      )
                    : null,
              ),
            ),
            if (subscription.lastRefreshedAt != null)
              Text(
                '上次刷新 ${_date(subscription.lastRefreshedAt!)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (subscription.lastError != null)
              Text(
                subscription.lastError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Wrap(
              spacing: 8,
              children: [
                if (selected)
                  const Chip(
                    label: Text('当前播放字幕组'),
                    avatar: Icon(Icons.check_circle_outline, size: 18),
                  ),
                if (!selected)
                  TextButton.icon(
                    onPressed: _busy == null && subscription.enabled
                        ? () => _run(
                            '正在切换字幕组',
                            (_) => widget.service.selectSubscription(
                              subscription.id,
                            ),
                          )
                        : null,
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('设为播放字幕组'),
                  ),
                TextButton.icon(
                  onPressed: _busy == null
                      ? () => _run(
                          '正在刷新字幕组',
                          (token) => widget.service.refresh(
                            subscriptionId: subscription.id,
                            cancelToken: token,
                          ),
                        )
                      : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新'),
                ),
                TextButton.icon(
                  onPressed: _busy == null ? () => _remove(subscription) : null,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除订阅'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _releaseCard(RssRelease release) {
    final canPlay =
        release.episodeNumber != null ||
        release.isSpecial ||
        (release.isBatch && release.episodeNumbers.isNotEmpty);
    final capability = widget.torrentService.capability;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(release.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              [
                if (release.group.isNotEmpty) release.group,
                if (release.quality.isNotEmpty) release.quality,
                if (release.sizeBytes != null) formatBytes(release.sizeBytes!),
                if (release.publishedAt != null) _date(release.publishedAt!),
              ].join(' · '),
            ),
            if (!canPlay)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('暂时无法确认话数，可下载后查看文件'),
              ),
            if (!capability.supported || !capability.ready)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  capability.unavailableReason ??
                      (_torrentInitialization != null
                          ? '正在准备磁力播放'
                          : '磁力引擎暂不可用'),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (canPlay)
                  FilledButton.icon(
                    onPressed:
                        _busy == null &&
                            capability.supported &&
                            capability.ready
                        ? () => _play(release)
                        : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('RSS 播放'),
                  ),
                OutlinedButton.icon(
                  onPressed:
                      _busy == null && capability.supported && capability.ready
                      ? () => _download(release)
                      : null,
                  icon: const Icon(Icons.download),
                  label: const Text('下载'),
                ),
              ],
            ),
          ],
        ),
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

String _date(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
String _episodeLabel(double number) =>
    number == number.truncateToDouble() ? '${number.toInt()}' : '$number';

class _LoadingRow extends StatelessWidget {
  const _LoadingRow({required this.label, required this.onCancel});
  final String label;
  final VoidCallback onCancel;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
        TextButton(onPressed: onCancel, child: const Text('取消')),
      ],
    ),
  );
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      children: [
        Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
        const SizedBox(width: 12),
        Expanded(child: Text(message)),
        TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}

class _ShowSelection extends StatelessWidget {
  const _ShowSelection({required this.shows});
  final List<MikanShow> shows;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 480,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('选择对应季度', style: Theme.of(context).textTheme.titleLarge),
        ),
        Expanded(
          child: shows.isEmpty
              ? const GeneralEmptyState(icon: Icons.search_off, title: '没有找到番组')
              : ListView(
                  children: [
                    for (final show in shows)
                      ListTile(
                        title: Text(show.title),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pop(context, show),
                      ),
                  ],
                ),
        ),
      ],
    ),
  );
}

class _GroupSelection extends StatelessWidget {
  const _GroupSelection({required this.show});
  final MikanShow show;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 480,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('选择字幕组', style: Theme.of(context).textTheme.titleLarge),
        ),
        Expanded(
          child: show.groups.isEmpty
              ? const GeneralEmptyState(
                  icon: Icons.group_off_outlined,
                  title: '这个番组还没有字幕组 RSS',
                )
              : ListView(
                  children: [
                    for (final group in show.groups)
                      ListTile(
                        leading: const Icon(Icons.rss_feed),
                        title: Text(group.name),
                        trailing: const Icon(Icons.add_rounded),
                        onTap: () => Navigator.pop(context, group),
                      ),
                  ],
                ),
        ),
      ],
    ),
  );
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
