import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/bean/widget/split_list_row.dart';
import 'package:kazumi/services/storage/image_cache_service.dart';
import 'package:kazumi/services/torrent/torrent_service.dart';
import 'package:kazumi/utils/format.dart';

class StorageSettingsPage extends StatefulWidget {
  const StorageSettingsPage({super.key});

  @override
  State<StorageSettingsPage> createState() => _StorageSettingsPageState();
}

class _StorageSettingsPageState extends State<StorageSettingsPage> {
  final _cache = ImageCacheService();
  late Future<int> _cacheSize = _cache.sizeInBytes();
  bool _clearing = false;
  final _torrents = inject<TorrentService>();
  late Future<({int tasks, int unused})> _torrentUsage = _torrents
      .storageUsage();
  bool _clearingTorrents = false;

  void _refreshSize() => setState(() => _cacheSize = _cache.sizeInBytes());

  Future<void> _confirmClearTorrents(int unused) async {
    if (_clearingTorrents) return;
    final confirmed = await KazumiDialog.show<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.hub_rounded),
        title: const Text('清理磁力缓存？'),
        content: Text(
          '删除播放留下的临时缓存和没有对应任务的文件，共 ${formatBytes(unused)}。任务列表里的下载不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearingTorrents = true);
    try {
      await _torrents.clearUnused();
      if (!mounted) return;
      _message('磁力缓存已清理');
    } catch (_) {
      if (mounted) _message('清理失败，请稍后重试');
    } finally {
      if (mounted) {
        setState(() {
          _clearingTorrents = false;
          _torrentUsage = _torrents.storageUsage();
        });
      }
    }
  }

  Widget _torrentTile() => _SettingsInset(
    child: FutureBuilder<({int tasks, int unused})>(
      future: _torrentUsage,
      builder: (context, snapshot) {
        final usage = snapshot.data;
        final ready =
            snapshot.connectionState == ConnectionState.done &&
            !snapshot.hasError;
        return SettingsTile(
          leading: Icons.hub_outlined,
          title: const Text('清理磁力缓存'),
          description: Text(
            _clearingTorrents
                ? '正在清理…'
                : !ready
                ? (snapshot.hasError ? '统计失败' : '正在统计…')
                : '任务 ${formatBytes(usage!.tasks)} · 可清理 ${formatBytes(usage.unused)}',
          ),
          enabled: ready && !_clearingTorrents && usage!.unused > 0,
          onPressed: (_) => _confirmClearTorrents(usage!.unused),
          trailing: const Icon(Icons.cleaning_services_rounded),
        );
      },
    ),
  );

  void _message(String message) {
    KazumiDialog.showToast(context: context, message: message);
  }

  Future<void> _confirmClear() async {
    if (_clearing) return;
    final confirmed = await KazumiDialog.show<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.cleaning_services_rounded),
        title: const Text('清除图片缓存？'),
        content: const Text('图片会在下次加载时重新下载。视频、记录和设置不会删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除缓存'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      await _cache.clear();
      if (!mounted) return;
      _message('图片缓存已清除');
      _refreshSize();
    } catch (_) {
      if (mounted) _message('清除失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  String _cacheDescription(AsyncSnapshot<int> snapshot) {
    if (_clearing) return '正在清除…';
    if (snapshot.connectionState != ConnectionState.done) return '正在统计…';
    if (snapshot.hasError) return '统计失败';
    return '${(snapshot.requireData / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) => SettingsDetailScaffold(
    title: const Text('存储与日志'),
    body: FutureBuilder<int>(
      future: _cacheSize,
      builder: (context, snapshot) => SettingsList(
        sections: [
          SettingsSection(
            title: const Text('缓存'),
            tiles: [
              SettingsTile(
                leading: Icons.image_outlined,
                title: const Text('清除图片缓存'),
                description: Text(_cacheDescription(snapshot)),
                enabled:
                    snapshot.connectionState == ConnectionState.done &&
                    !_clearing,
                onPressed: (_) => _confirmClear(),
                trailing:
                    snapshot.connectionState == ConnectionState.done &&
                        snapshot.hasError &&
                        !_clearing
                    ? IconButton(
                        tooltip: '重新统计',
                        onPressed: _refreshSize,
                        icon: const Icon(Icons.refresh_rounded),
                      )
                    : const Icon(Icons.cleaning_services_rounded),
              ),
              _torrentTile(),
            ],
          ),
          SettingsSection(
            title: const Text('诊断'),
            tiles: [
              SettingsTile(
                leading: Icons.receipt_long_rounded,
                title: const Text('错误日志'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onPressed: (_) => context.pushNamed('/settings/storage/logs'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Gives a wrapped settings tile the separator inset of tiles with an icon.
class _SettingsInset extends StatelessWidget implements SplitListDividerInset {
  const _SettingsInset({required this.child});

  final Widget child;

  @override
  double get dividerInset => 16 + 22 + 14;

  @override
  Widget build(BuildContext context) => child;
}
