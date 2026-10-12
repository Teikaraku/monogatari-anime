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
  rules,
  history,
  downloads,
  sync,
  storage,
  about,
}

/// iOS system colours used for the symbol tiles, as in the Monogatari settings.
abstract final class _Tint {
  static const blue = Color(0xFF007AFF);
  static const green = Color(0xFF34C759);
  static const indigo = Color(0xFF5856D6);
  static const orange = Color(0xFFFF9500);
  static const teal = Color(0xFF30B0C7);
  static const gray = Color(0xFF8E8E93);
}

class MySpaceView extends StatelessWidget {
  const MySpaceView({
    super.key,
    required this.stats,
    required this.onOpen,
  });

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
        child: LayoutBuilder(builder: (context, constraints) {
          final largeText = MediaQuery.textScalerOf(context).scale(16) > 24;
          final wide = _isWide(constraints.maxWidth, context);
          final preferences = ContentSection.group(
            title: '内容与偏好',
            children: [
              _entry('规则设置', '管理番剧来源', Icons.extension_rounded,
                  _Tint.orange, MyDestination.rules),
              _entry('外观设置', '主题、配色与字体', Icons.palette_rounded,
                  _Tint.blue, MyDestination.theme),
              _entry('播放设置', '解码、渲染与播放行为', Icons.play_arrow_rounded,
                  _Tint.green, MyDestination.player),
              _entry('弹幕设置', '弹幕来源与显示效果', Icons.subtitles_rounded,
                  _Tint.indigo, MyDestination.danmaku),
            ],
          );
          final data = ContentSection.group(
            title: '数据与应用',
            children: [
              _entry('同步备份', '跨设备同步数据', Icons.cloud_sync_rounded,
                  _Tint.teal, MyDestination.sync),
              _entry('存储管理', '缓存与日志', Icons.cleaning_services_rounded,
                  _Tint.gray, MyDestination.storage),
              _entry('关于 ${AppBrand.name}', '版本与开源信息', Icons.info_outline_rounded,
                  _Tint.gray, MyDestination.about),
            ],
          );
          return SingleChildScrollView(
            key: const PageStorageKey('my-space'),
            padding: const EdgeInsets.fromLTRB(
                _sidePadding, 4, _sidePadding, 32),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: _maxWidth(wide)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _WatchStatsPanel(
                      bangumiCount: stats.watchedBangumiCount,
                      episodeCount: stats.watchedEpisodeCount,
                    ),
                    const SizedBox(height: 12),
                    _AdaptivePair(
                      stack: constraints.maxWidth < 300 || largeText,
                      first: _ToolTile(
                        icon: Icons.history_rounded,
                        color: _Tint.blue,
                        title: '历史记录',
                        caption: stats.watchedBangumiCount == 0
                            ? '暂无观看记录'
                            : '查看观看记录',
                        onTap: () => onOpen(MyDestination.history),
                      ),
                      second: _ToolTile(
                        icon: Icons.download_rounded,
                        color: monogatariPink,
                        title: '离线下载',
                        caption: stats.downloadTaskCount == 0
                            ? '管理离线内容'
                            : '${stats.downloadTaskCount} 集下载任务',
                        onTap: () => onOpen(MyDestination.downloads),
                      ),
                    ),
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
        }),
      ),
    );
  }

  Widget _entry(String title, String description, IconData icon, Color color,
          MyDestination destination) =>
      SettingsCategoryTile(
        icon: icon,
        color: color,
        title: title,
        description: description,
        onTap: () => onOpen(destination),
      );
}

class _WatchStatsPanel extends StatelessWidget {
  const _WatchStatsPanel({
    required this.bangumiCount,
    required this.episodeCount,
  });

  final int bangumiCount;
  final int episodeCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = MonoPalette.of(context);
    return Material(
      color: palette.groupedCell,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // A soft wash of the accent keeps the card from reading as a plain row.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    colors.primary.withValues(alpha: 0.12),
                    colors.primary.withValues(alpha: 0.02),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome_rounded,
                        size: 16, color: colors.primary),
                    const SizedBox(width: 6),
                    Semantics(
                      header: true,
                      child: Text(
                        '观看足迹',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: colors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                IntrinsicHeight(
                  child: Row(
                    children: [
                      Expanded(
                        child: _StatCount(value: bangumiCount, label: '看过番剧'),
                      ),
                      VerticalDivider(
                        width: 32,
                        thickness: 0.5,
                        color: palette.hairline,
                      ),
                      Expanded(
                        child: _StatCount(value: episodeCount, label: '观看集数'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCount extends StatelessWidget {
  const _StatCount({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Scale large totals without shrinking their labels.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text('$value',
              style: theme.textTheme.displaySmall?.copyWith(
                  fontSize: 32,
                  height: 1.1,
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ),
        const SizedBox(height: 4),
        Text(label,
            style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 13, color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.caption,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String caption;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = MonoPalette.of(context);
    return Semantics(
      button: true,
      child: Material(
        color: palette.groupedCell,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
            child: Row(
              children: [
                SettingsIconTile(icon: icon, color: color, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    size: 22, color: palette.tertiaryLabel),
              ],
            ),
          ),
        ),
      ),
    );
  }
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

class _AdaptivePair extends StatelessWidget {
  const _AdaptivePair({
    required this.first,
    required this.second,
    this.stack = false,
  });

  final Widget first;
  final Widget second;
  final bool stack;

  @override
  Widget build(BuildContext context) {
    if (stack) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [first, const SizedBox(height: 12), second],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: first),
          const SizedBox(width: 12),
          Expanded(child: second),
        ],
      ),
    );
  }
}
