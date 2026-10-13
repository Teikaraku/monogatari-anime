import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/download/background_download_service.dart';
import 'package:kazumi/services/torrent/torrent_models.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:kazumi/utils/format.dart';

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

  Future<void> _delete(TorrentTaskSnapshot task) async {
    final deleteFiles = await showDialog<bool>(
      context: context,
      builder: (context) => _DeleteTaskDialog(title: task.title),
    );
    if (deleteFiles == null || !mounted) return;
    await _perform(
      task.id,
      () => widget.service.delete(task.id, deleteFiles: deleteFiles),
    );
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
    return Scaffold(
      appBar: const SysAppBar(title: Text('磁力任务')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Column(
            children: [
              if (Platform.isIOS)
                const _MessageRow(
                  message: 'iOS 的后台运行受系统限制；磁力下载时请保持应用在前台，切到后台后任务可能中断。',
                ),
              if (!_capability.supported || !_capability.ready)
                _MessageRow(
                  message: _capability.unavailableReason ?? '磁力引擎暂不可用',
                ),
              if (_error != null)
                _MessageRow(
                  message: _error!,
                  onRetry: _loading ? null : () => _initialize(_revision),
                ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : tasks.isEmpty
                    ? const GeneralEmptyState(
                        icon: Icons.downloading_rounded,
                        title: '还没有磁力任务',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: tasks.length,
                        itemBuilder: (context, index) =>
                            _taskCard(tasks[index]),
                        findChildIndexCallback: (key) => key is ValueKey<String>
                            ? taskIndices[key.value]
                            : null,
                      ),
              ),
            ],
          ),
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
    }.contains(task.state);
    final resumable = const {
      TorrentTaskState.paused,
      TorrentTaskState.cancelled,
      TorrentTaskState.error,
    }.contains(task.state);
    final progress = task.progress.isFinite
        ? task.progress.clamp(0.0, 1.0).toDouble()
        : 0.0;
    return Card(
      key: ValueKey(task.id),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(task.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(_status(task)),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: task.totalBytes > 0
                  ? progress
                  : active
                  ? null
                  : 0,
            ),
            const SizedBox(height: 8),
            Text(
              [
                '${formatBytes(task.downloadedBytes)} / ${task.totalBytes > 0 ? formatBytes(task.totalBytes) : '大小待获取'}',
                if (active) formatSpeed(task.downloadBytesPerSecond.toDouble()),
                if (active) '${task.peers} 个连接',
              ].join(' · '),
            ),
            if (task.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  task.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (task.bangumiId == null &&
                task.files.any((file) => file.isVideo))
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('任务未绑定番组，暂时不能在应用内播放'),
              ),
            if (task.files.isNotEmpty)
              ExpansionTile(
                key: PageStorageKey('torrent-files:${task.id}'),
                title: Text(
                  '${task.files.where((file) => file.isVideo).length} 个视频文件',
                ),
                tilePadding: EdgeInsets.zero,
                children: [
                  for (final file in task.files.where((file) => file.isVideo))
                    ListTile(
                      dense: true,
                      title: Text(file.name),
                      subtitle: Text(
                        '${formatBytes(file.downloadedBytes)} / ${formatBytes(file.size)}',
                      ),
                      trailing: IconButton(
                        tooltip: '播放该文件',
                        icon: const Icon(Icons.play_circle_outline),
                        onPressed: task.bangumiId == null || busy
                            ? null
                            : () => _playFile(task, file),
                      ),
                    ),
                ],
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (task.bangumiId != null)
                  TextButton.icon(
                    onPressed: busy ? null : () => _openSubject(task),
                    icon: const Icon(Icons.movie_outlined),
                    label: const Text('对应番组'),
                  ),
                if (active)
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => _perform(
                            task.id,
                            () => widget.service.pause(task.id),
                          ),
                    icon: const Icon(Icons.pause),
                    label: const Text('暂停'),
                  ),
                if (resumable)
                  FilledButton.icon(
                    onPressed: busy || !_capability.ready
                        ? null
                        : () => _perform(task.id, () async {
                            await BackgroundDownloadService().resumeForUser();
                            if (mounted) await widget.service.resume(task.id);
                          }),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(
                      task.state == TorrentTaskState.error ? '重试' : '继续',
                    ),
                  ),
                if (active || task.state == TorrentTaskState.paused)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => _perform(
                            task.id,
                            () => widget.service.cancel(task.id),
                          ),
                    child: const Text('取消任务'),
                  ),
                TextButton.icon(
                  onPressed: busy ? null : () => _delete(task),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _status(TorrentTaskSnapshot task) => switch (task.state) {
    TorrentTaskState.metadata => '正在获取文件信息',
    TorrentTaskState.downloading =>
      '下载中 · ${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
    TorrentTaskState.buffering =>
      task.streamReady ? '正在播放 · 按需缓冲' : '正在缓冲播放所需内容',
    TorrentTaskState.paused => '已暂停',
    TorrentTaskState.cancelled => '已取消，已下载内容保留',
    TorrentTaskState.completed => '已完成',
    TorrentTaskState.error => '任务失败',
  };
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        const Icon(Icons.info_outline),
        const SizedBox(width: 12),
        Expanded(child: Text(message)),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}

class _DeleteTaskDialog extends StatefulWidget {
  const _DeleteTaskDialog({required this.title});
  final String title;
  @override
  State<_DeleteTaskDialog> createState() => _DeleteTaskDialogState();
}

class _DeleteTaskDialogState extends State<_DeleteTaskDialog> {
  bool _deleteFiles = false;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('删除磁力任务'),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.title),
          const SizedBox(height: 12),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('同时删除已下载文件'),
            value: _deleteFiles,
            onChanged: (value) => setState(() => _deleteFiles = value ?? false),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _deleteFiles),
        child: const Text('删除任务'),
      ),
    ],
  );
}
