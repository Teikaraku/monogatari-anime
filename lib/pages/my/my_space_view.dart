import 'package:kazumi/utils/app_brand.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/bean/widget/content_section.dart';
import 'package:kazumi/bean/widget/split_list_row.dart';
import 'package:kazumi/modules/my/watch_stats.dart';
import 'package:kazumi/utils/theme.dart';

enum MyDestination {
  theme,
  interface,
  player,
  danmaku,
  keyboard,
  downloadSettings,
  history,
  downloads,
  subscriptions,
  torrentTasks,
  stats,
  sync,
  proxy,
  update,
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
            final rss = ContentSection.group(
              title: 'RSS',
              children: [
                _entry(
                  'RSS 订阅',
                  '番组与字幕组更新',
                  Icons.rss_feed_rounded,
                  _Tint.orange,
                  MyDestination.subscriptions,
                ),
                _entry(
                  '磁力任务',
                  '缓冲与下载进度',
                  Icons.hub_rounded,
                  _Tint.teal,
                  MyDestination.torrentTasks,
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
                  '界面设置',
                  '启动、窗口行为与展示信息',
                  Icons.pages_rounded,
                  _Tint.teal,
                  MyDestination.interface,
                ),
                _entry(
                  '播放设置',
                  '解码、渲染与播放行为',
                  Icons.display_settings_rounded,
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
                _entry(
                  '操作设置',
                  '播放器按键映射',
                  Icons.keyboard_rounded,
                  _Tint.gray,
                  MyDestination.keyboard,
                ),
                _entry(
                  '下载设置',
                  '并发数与弹幕缓存',
                  Icons.downloading_rounded,
                  monogatariPink,
                  MyDestination.downloadSettings,
                ),
              ],
            );
            final data = ContentSection.group(
              title: '数据与应用',
              children: [
                _entry(
                  '同步设置',
                  '追番状态与多设备同步',
                  Icons.cloud_rounded,
                  _Tint.blue,
                  MyDestination.sync,
                ),
                _entry(
                  '网络设置',
                  '访问加速与代理',
                  Icons.language_rounded,
                  _Tint.green,
                  MyDestination.proxy,
                ),
                _entry(
                  '更新设置',
                  '应用更新检查',
                  Icons.update_rounded,
                  _Tint.orange,
                  MyDestination.update,
                ),
                _entry(
                  '存储与日志',
                  '图片缓存与错误日志',
                  Icons.storage_rounded,
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
            Widget pair(Widget start, Widget end) => wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: start),
                      const SizedBox(width: 16),
                      Expanded(child: end),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [start, const SizedBox(height: 28), end],
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
                      pair(watching, rss),
                      const SizedBox(height: 28),
                      pair(preferences, data),
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
