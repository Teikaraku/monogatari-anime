import 'package:kazumi/utils/app_brand.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/bean/widget/content_section.dart';
import 'package:kazumi/bean/widget/split_list_row.dart';
import 'package:kazumi/modules/my/watch_stats.dart';
import 'package:kazumi/utils/theme.dart';

enum MyDestination {
  theme,
  player,
  danmaku,
  history,
  downloads,
  subscriptions,
  torrentTasks,
  stats,
  sync,
  storage,
  about,
}

/// iOS system colours used for the symbol tiles, as in the Monogatari settings.
abstract final class _Tint {
  static const blue = Color(0xFF007AFF);
  static const green = Color(0xFF34C759);
  static const indigo = Color(0xFF5856D6);
  static const teal = Color(0xFF30B0C7);
  static const purple = Color(0xFFAF52DE);
  static const orange = Color(0xFFFF9500);
  static const gray = Color(0xFF8E8E93);
}

class MySpaceView extends StatelessWidget {
  const MySpaceView({super.key, required this.stats, required this.onOpen});

  final WatchStats stats;
  final ValueChanged<MyDestination> onOpen;

  static const double _sidePadding = 16;
  static double _maxWidth(bool wide) => wide ? 980 : 720;
  static bool _isWide(double width, BuildContext? context) =>
      width >= 760 &&
      (context == null || MediaQuery.textScalerOf(context).scale(16) <= 24);

  /// Width of the content column with its padding, for aligning the title.
  static double contentWidthFor(double pageWidth) =>
      _maxWidth(_isWide(pageWidth, null)) + _sidePadding * 2;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: MonoPalette.of(context).groupedBackground,
      child: MonoGroupedScope(
        grouped: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = _isWide(constraints.maxWidth, context);
            final watching = ContentSection.group(
              title: '观看',
              children: [
                _entry(
                  '历史记录',
                  stats.watchedBangumiCount == 0 ? '暂无观看记录' : '查看观看记录',
                  Icons.history_rounded,
                  _Tint.blue,
                  MyDestination.history,
                ),
                _entry(
                  '离线下载',
                  stats.downloadTaskCount == 0
                      ? '管理离线内容'
                      : '${stats.downloadTaskCount} 集下载任务',
                  Icons.download_rounded,
                  monogatariPink,
                  MyDestination.downloads,
                ),
                _entry(
                  'RSS 订阅',
                  '订阅番组与字幕组更新',
                  Icons.rss_feed_rounded,
                  _Tint.orange,
                  MyDestination.subscriptions,
                ),
                _entry(
                  '磁力任务',
                  '查看缓冲与下载进度',
                  Icons.downloading_rounded,
                  _Tint.teal,
                  MyDestination.torrentTasks,
                ),
                _entry(
                  '观看统计',
                  stats.watchedEpisodeCount == 0
                      ? '观看热力图'
                      : '共看过 ${stats.watchedEpisodeCount} 集',
                  Icons.insights_rounded,
                  _Tint.purple,
                  MyDestination.stats,
                ),
              ],
            );
            final preferences = ContentSection.group(
              title: '内容与偏好',
              children: [
                _entry(
                  '外观设置',
                  '主题、配色与字体',
                  Icons.palette_rounded,
                  _Tint.blue,
                  MyDestination.theme,
                ),
                _entry(
                  '播放设置',
                  '解码、渲染与播放行为',
                  Icons.play_arrow_rounded,
                  _Tint.green,
                  MyDestination.player,
                ),
                _entry(
                  '弹幕设置',
                  '弹幕来源与显示效果',
                  Icons.subtitles_rounded,
                  _Tint.indigo,
                  MyDestination.danmaku,
                ),
              ],
            );
            final data = ContentSection.group(
              title: '数据与应用',
              children: [
                _entry(
                  '同步备份',
                  '跨设备同步数据',
                  Icons.cloud_sync_rounded,
                  _Tint.teal,
                  MyDestination.sync,
                ),
                _entry(
                  '存储管理',
                  '缓存与日志',
                  Icons.cleaning_services_rounded,
                  _Tint.gray,
                  MyDestination.storage,
                ),
                _entry(
                  '关于 ${AppBrand.name}',
                  '版本与开源信息',
                  Icons.info_outline_rounded,
                  _Tint.gray,
                  MyDestination.about,
                ),
              ],
            );
            return SingleChildScrollView(
              key: const PageStorageKey('my-space'),
              padding: const EdgeInsets.fromLTRB(
                _sidePadding,
                4,
                _sidePadding,
                32,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: _maxWidth(wide)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      watching,
                      const SizedBox(height: 28),
                      if (wide)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: preferences),
                            const SizedBox(width: 16),
                            Expanded(child: data),
                          ],
                        )
                      else ...[
                        preferences,
                        const SizedBox(height: 28),
                        data,
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _entry(
    String title,
    String description,
    IconData icon,
    Color color,
    MyDestination destination,
  ) => SettingsCategoryTile(
    icon: icon,
    color: color,
    title: title,
    description: description,
    onTap: () => onOpen(destination),
  );
}

class MySettingsButton extends StatelessWidget {
  const MySettingsButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '全部设置',
      onPressed: onTap,
      icon: const Icon(Icons.settings_outlined),
    );
  }
}
