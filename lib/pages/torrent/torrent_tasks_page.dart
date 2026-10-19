import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
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
import 'package:kazumi/services/torrent/torrent_models.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:kazumi/utils/format.dart';
import 'package:kazumi/utils/theme.dart';

class TorrentTasksPage extends StatefulWidget {
  const TorrentTasksPage({super.key, required this.service, this.subjectId});
  final TorrentService service;
  final int? subjectId;

  @override
  State<TorrentTasksPage> createState() => _TorrentTasksPageState();
}

class _TorrentTasksPageState extends State<TorrentTasksPage> {
  StreamSubscription<List<TorrentTaskSnapshot>>? _tasksSubscription;
  StreamSubscription<TorrentCapability>? _capabilitySubscription;
  List<TorrentTaskSnapshot> _tasks = [];
  late TorrentCapability _capability;
  final Set<String> _busy = {};

  /// Tasks whose file list is open, by id so the state follows reordering.
  final Set<String> _expanded = {};
  String? _error;
  bool _loading = true;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(covariant TorrentTasksPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      unawaited(_tasksSubscription?.cancel());
      unawaited(_capabilitySubscription?.cancel());
      _attach();
    }
  }

  void _attach() {
    final revision = ++_revision;
    _busy.clear();
    _loading = true;
    _capability = widget.service.capability;
    _tasks = widget.service.tasks;
    _tasksSubscription = widget.service.watchTasks.listen(
      (tasks) {
        if (mounted && revision == _revision) setState(() => _tasks = tasks);
      },
      onError: (Object _) {
        if (mounted && revision == _revision) {
          setState(() => _error = '读取磁力任务失败，请重试');
        }
      },
    );
    _capabilitySubscription = widget.service.watchCapability.listen(
      (value) {
        if (mounted && revision == _revision) {
          setState(() => _capability = value);
        }
      },
      onError: (Object _) {
        if (mounted && revision == _revision) {
          setState(() => _error = '读取磁力引擎状态失败，请重试');
        }
      },
    );
    unawaited(_initialize(revision));
  }

  Future<void> _initialize(int revision) async {
    try {
      await widget.service.initialize();
      if (!mounted || revision != _revision) return;
      setState(() {
        _tasks = widget.service.tasks;
        _capability = widget.service.capability;
        _error = null;
      });
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() => _error = '磁力引擎启动失败，请重试');
      }
    } finally {
      if (mounted && revision == _revision) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _revision++;
    unawaited(_tasksSubscription?.cancel());
    unawaited(_capabilitySubscription?.cancel());
    super.dispose();
  }

  Future<void> _perform(String id, Future<void> Function() action) async {
    if (_busy.contains(id)) return;
    final revision = _revision;
    setState(() {
      _busy.add(id);
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() => _error = '任务操作失败，请重试');
      }
    } finally {
      if (mounted && revision == _revision) setState(() => _busy.remove(id));
    }
  }

  Future<void> _openSubject(TorrentTaskSnapshot task) async {
    final id = task.bangumiId;
    if (id == null) return;
    await _perform(task.id, () async {
      final result = await BangumiApi.getBangumiSubjectByID(id);
      if (result == null) throw StateError('条目不可用');
      if (mounted) await context.pushNamed('/info/', arguments: result.$1);
    });
  }

  // Files live in the app's private storage; a kept copy could never be
  // reached again, so a task is always deleted with its files.
  Future<void> _delete(TorrentTaskSnapshot task) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => _DeleteTaskDialog(title: task.title),
    );
    if (accepted != true || !mounted) return;
    await _perform(
      task.id,
      () => widget.service.delete(task.id, deleteFiles: true),
    );
  }

  Future<void> _openFolder(TorrentTaskSnapshot task) async {
    final path = await widget.service.filesPath(task.id);
    if (path == null) return;
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [path]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [path]);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [path]);
    }
  }

  Future<void> _playFile(TorrentTaskSnapshot task, TorrentFileInfo file) async {
    final id = task.bangumiId;
    if (id == null) return;
    await BackgroundDownloadService().resumeForUser();
    if (!mounted) return;
    BangumiItem? cachedSubject;
    final data = task.subjectData;
    if (data != null) {
      try {
        final parsed = BangumiItem.fromJson(Map<String, dynamic>.from(data));
        if (parsed.id == id) cachedSubject = parsed;
      } catch (_) {
        // Older or damaged task metadata must not block local file playback.
      }
    }
    final subject =
        cachedSubject ??
        BangumiItem(
          id: id,
          type: 2,
          name: task.title,
          nameCn: task.title,
          summary: '',
          airDate: '',
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
    context.pushNamed(
      '/video/',
      arguments: OnlineVideoPlaybackArgs(
        bangumiItem: subject,
        playbackSource: 'rss',
        torrentTaskId: task.id,
        torrentFileIndex: file.index,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _tasks
        .where(
          (task) =>
              widget.subjectId == null || task.bangumiId == widget.subjectId,
        )
        .toList();
    final taskIndices = {
      for (var index = 0; index < tasks.length; index++) tasks[index].id: index,
    };
    final banners = [
      if (Platform.isIOS)
        const RssBanner(
          message: 'iOS 切到后台后，磁力任务可能中断',
          tone: RssBannerTone.info,
        ),
      if (!_capability.supported || !_capability.ready)
        RssBanner(
          message: _capability.unavailableReason ?? '磁力引擎暂不可用',
          tone: RssBannerTone.info,
        ),
      if (_error != null)
        RssBanner(
          message: _error!,
          tone: RssBannerTone.error,
          actionLabel: _loading ? null : '重试',
          onAction: _loading ? null : () => _initialize(_revision),
        ),
    ];
    Widget readable(Widget child) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: settingsReadableWidth),
        child: child,
      ),
    );
    return SettingsDetailScaffold(
      title: const Text('磁力任务'),
      body: MonoGroupedScope(
        grouped: true,
        child: _loading
            ? const Center(child: LoadingIndicator())
            : tasks.isEmpty
            ? Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Column(
                  children: [
                    for (final banner in banners) readable(banner),
                    const Expanded(
                      child: GeneralEmptyState(
                        icon: Icons.hub_rounded,
                        title: '还没有磁力任务',
                      ),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                padding: EdgeInsets.fromLTRB(
                  16,
                  4,
                  16,
                  32 + MediaQuery.paddingOf(context).bottom,
                ),
                itemCount: banners.length + tasks.length,
                itemBuilder: (context, index) => readable(
                  index < banners.length
                      ? banners[index]
                      : _taskCard(tasks[index - banners.length]),
                ),
                findChildIndexCallback: (key) => key is ValueKey<String>
                    ? switch (taskIndices[key.value]) {
                        final index? => index + banners.length,
                        null => null,
                      }
                    : null,
              ),
      ),
    );
  }

  Widget _taskCard(TorrentTaskSnapshot task) {
    final busy = _busy.contains(task.id);
    final active = const {
      TorrentTaskState.metadata,
      TorrentTaskState.downloading,
      TorrentTaskState.buffering,
      TorrentTaskState.queued,
    }.contains(task.state);
    final resumable = const {
      TorrentTaskState.paused,
      TorrentTaskState.cancelled,
      TorrentTaskState.error,
    }.contains(task.state);
    final progress = task.progress.isFinite
        ? task.progress.clamp(0.0, 1.0).toDouble()
        : 0.0;
    final colors = Theme.of(context).colorScheme;
    final palette = MonoPalette.of(context);
    final videos = task.files.where((file) => file.isVideo).toList();
    final bound = task.bangumiId != null;
    final expanded = _expanded.contains(task.id);
    final tone = switch (task.state) {
      TorrentTaskState.completed => palette.success,
      TorrentTaskState.error => colors.error,
      TorrentTaskState.paused || TorrentTaskState.queued ||
      TorrentTaskState.cancelled => palette.secondaryLabel,
      _ => colors.primary,
    };

    final Widget? primary = busy
        ? const SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        : active
        ? _RoundAction(
            tooltip: '暂停',
            icon: Icons.pause_rounded,
            onPressed: () =>
                _perform(task.id, () => widget.service.pause(task.id)),
          )
        : resumable
        ? _RoundAction(
            tooltip: task.state == TorrentTaskState.error ? '重试' : '继续',
            icon: task.state == TorrentTaskState.error
                ? Icons.refresh_rounded
                : Icons.play_arrow_rounded,
            onPressed: !_capability.ready
                ? null
                : () => _perform(task.id, () async {
                    await BackgroundDownloadService().resumeForUser();
                    if (mounted) {
                      await widget.service.resume(task.id);
                    }
                  }),
          )
        : task.state == TorrentTaskState.completed &&
              bound &&
              videos.length == 1
        ? _RoundAction(
            tooltip: '播放',
            icon: Icons.play_arrow_rounded,
            onPressed: () => _playFile(task, videos.single),
          )
        : null;

    final speed = active && task.state != TorrentTaskState.metadata
        ? [
            '↓ ${formatSpeed(task.downloadBytesPerSecond.toDouble())}',
            if (task.uploadBytesPerSecond > 0)
              '↑ ${formatSpeed(task.uploadBytesPerSecond.toDouble())}',
            '${task.peers} 个连接',
          ].join(' · ')
        : null;

    return Padding(
      key: ValueKey(task.id),
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: palette.groupedCell,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              task.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                height: 1.35,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _status(task),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: tone,
                              ),
                            ),
                            if (task.notice != null &&
                                (task.state == TorrentTaskState.paused ||
                                    task.state == TorrentTaskState.queued))
                              Text(
                                task.notice!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: palette.secondaryLabel,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      ?primary,
                      _taskMenu(task, busy: busy, active: active),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _ProgressBar(
                      color: tone,
                      value: task.totalBytes > 0
                          ? progress
                          : active
                          ? null
                          : 0,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: DefaultTextStyle.merge(
                      style: TextStyle(
                        fontSize: 12,
                        color: palette.secondaryLabel,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              task.totalBytes > 0
                                  ? '${formatBytes(task.downloadedBytes)} / ${formatBytes(task.totalBytes)}'
                                  : formatBytes(task.downloadedBytes),
                            ),
                          ),
                          if (speed != null) Text(speed),
                        ],
                      ),
                    ),
                  ),
                  if (task.error != null) ...[
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(
                        task.error!,
                        style: TextStyle(fontSize: 13, color: colors.error),
                      ),
                    ),
                  ],
                  if (!bound && videos.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      '未关联番剧，无法在应用内播放',
                      style: TextStyle(
                        fontSize: 13,
                        color: palette.secondaryLabel,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (videos.isNotEmpty) ...[
              Divider(height: 0.5, thickness: 0.5, color: palette.hairline),
              InkWell(
                onTap: () => setState(() {
                  if (!_expanded.remove(task.id)) _expanded.add(task.id);
                }),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.movie_outlined,
                        size: 18,
                        color: palette.secondaryLabel,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${videos.length} 个视频文件',
                          style: TextStyle(
                            fontSize: 14,
                            color: palette.secondaryLabel,
                          ),
                        ),
                      ),
                      AnimatedRotation(
                        turns: expanded ? 0.25 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(
                          Icons.chevron_right_rounded,
                          color: palette.tertiaryLabel,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOutCubic,
                alignment: Alignment.topCenter,
                child: !expanded
                    ? const SizedBox(width: double.infinity)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final file in videos) ...[
                            Divider(
                              height: 0.5,
                              thickness: 0.5,
                              indent: 16,
                              color: palette.hairline,
                            ),
                            RssRow(
                              title: file.name,
                              titleMaxLines: 3,
                              subtitle:
                                  '${formatBytes(file.downloadedBytes)} / ${formatBytes(file.size)}',
                              trailing: IconButton(
                                tooltip: '播放该文件',
                                color: colors.primary,
                                icon: const Icon(
                                  Icons.play_circle_outline_rounded,
                                ),
                                onPressed: !bound || busy
                                    ? null
                                    : () => _playFile(task, file),
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _taskMenu(
    TorrentTaskSnapshot task, {
    required bool busy,
    required bool active,
  }) {
    return KazumiMenuButton(
      enabled: !busy,
      menuChildren: [
        if (task.bangumiId != null)
          KazumiMenuItem(
            label: '对应番组',
            leadingIcon: const Icon(Icons.movie_outlined),
            onPressed: () => _openSubject(task),
          ),
        if (_desktop && task.downloadedBytes > 0)
          KazumiMenuItem(
            label: '打开文件夹',
            leadingIcon: const Icon(Icons.folder_open_outlined),
            onPressed: () => unawaited(_openFolder(task)),
          ),
        if (active || task.state == TorrentTaskState.paused ||
            task.state == TorrentTaskState.queued)
          KazumiMenuItem(
            label: '取消任务',
            leadingIcon: const Icon(Icons.stop_circle_outlined),
            onPressed: () =>
                _perform(task.id, () => widget.service.cancel(task.id)),
          ),
        KazumiMenuItem(
          label: '删除',
          leadingIcon: const Icon(Icons.delete_outline_rounded),
          destructive: true,
          onPressed: () => _delete(task),
        ),
      ],
      builder: (context, toggle) =>
          RssMoreButton(tooltip: '任务选项', onPressed: toggle),
    );
  }

  static bool get _desktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  String _status(TorrentTaskSnapshot task) => switch (task.state) {
    TorrentTaskState.metadata => '正在获取文件信息',
    TorrentTaskState.downloading =>
      '下载中 ${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
    TorrentTaskState.buffering => task.streamReady ? '正在播放' : '正在缓冲',
    TorrentTaskState.paused => '已暂停',
    TorrentTaskState.queued => '等待自动继续',
    TorrentTaskState.cancelled => '已取消',
    TorrentTaskState.completed => '已完成',
    TorrentTaskState.error => '下载失败',
  };
}

/// A plain rounded bar; indeterminate while the size is unknown.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.color, required this.value});

  final Color color;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final track = MonoPalette.of(context).fill;
    final radius = BorderRadius.circular(2);
    if (value == null) {
      return LinearProgressIndicator(
        minHeight: 4,
        color: color,
        backgroundColor: track,
        borderRadius: radius,
      );
    }
    return Container(
      height: 4,
      decoration: BoxDecoration(color: track, borderRadius: radius),
      alignment: AlignmentDirectional.centerStart,
      child: FractionallySizedBox(
        widthFactor: value!.clamp(0.0, 1.0),
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, borderRadius: radius),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// The task's main control: a tinted round button.
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IconButton.filled(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: colors.primary.withValues(alpha: 0.12),
        foregroundColor: colors.primary,
      ),
      icon: Icon(icon),
    );
  }
}

class _DeleteTaskDialog extends StatelessWidget {
  const _DeleteTaskDialog({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('删除磁力任务'),
      content: SizedBox(width: 480, child: Text('「$title」和已下载的文件会一起删除。')),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: colors.error,
            foregroundColor: colors.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除任务'),
        ),
      ],
    );
  }
}
