import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/bean/widget/content_section.dart';
import 'package:kazumi/pages/settings/player_settings.dart';
import 'package:kazumi/bean/widget/split_list_row.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/theme.dart';

class _SettingsCategory {
  const _SettingsCategory({
    required this.label,
    required this.description,
    required this.icon,
    required this.path,
    required this.color,
  });

  final String label;
  final String description;
  final IconData icon;
  final String path;
  final Color color;
}

class _SettingsGroup {
  const _SettingsGroup({required this.title, required this.categories});

  final String title;
  final List<_SettingsCategory> categories;
}

const List<_SettingsGroup> _settingsGroups = [
  _SettingsGroup(
    title: '播放',
    categories: [
      _SettingsCategory(
        label: '播放设置',
        description: '解码、渲染与播放行为',
        icon: Icons.display_settings_rounded,
        path: '/settings/player',
        color: Color(0xFF34C759),
      ),
      _SettingsCategory(
        label: '弹幕设置',
        description: '弹幕来源与显示效果',
        icon: Icons.subtitles_rounded,
        path: '/settings/danmaku',
        color: Color(0xFF5856D6),
      ),
      _SettingsCategory(
        label: '操作设置',
        description: '播放器按键映射',
        icon: Icons.keyboard_rounded,
        path: '/settings/keyboard',
        color: Color(0xFF8E8E93),
      ),
    ],
  ),
  _SettingsGroup(
    title: '资源',
    categories: [
      _SettingsCategory(
        label: '规则管理',
        description: '番剧资源规则',
        icon: Icons.extension_rounded,
        path: '/settings/plugin',
        color: Color(0xFFFF9500),
      ),
      _SettingsCategory(
        label: '下载设置',
        description: '并发数与弹幕缓存',
        icon: Icons.downloading_rounded,
        path: '/settings/download-settings',
        color: Color(0xFFFF2D55),
      ),
    ],
  ),
  _SettingsGroup(
    title: '应用',
    categories: [
      _SettingsCategory(
        label: '外观设置',
        description: '主题、配色与字体',
        icon: Icons.palette_rounded,
        path: '/settings/theme',
        color: Color(0xFF007AFF),
      ),
      _SettingsCategory(
        label: '界面设置',
        description: '启动、窗口行为与展示信息',
        icon: Icons.pages_rounded,
        path: '/settings/interface',
        color: Color(0xFF30B0C7),
      ),
      _SettingsCategory(
        label: '同步设置',
        description: '追番状态与多设备同步',
        icon: Icons.cloud_rounded,
        path: '/settings/sync',
        color: Color(0xFF007AFF),
      ),
      _SettingsCategory(
        label: '网络设置',
        description: '访问加速与代理',
        icon: Icons.language_rounded,
        path: '/settings/proxy',
        color: Color(0xFF34C759),
      ),
    ],
  ),
  _SettingsGroup(
    title: '其他',
    categories: [
      _SettingsCategory(
        label: '更新设置',
        description: '应用与规则更新',
        icon: Icons.update_rounded,
        path: '/settings/update',
        color: Color(0xFFFF9500),
      ),
      _SettingsCategory(
        label: '存储与日志',
        description: '图片缓存与错误日志',
        icon: Icons.storage_rounded,
        path: '/settings/storage',
        color: Color(0xFF8E8E93),
      ),
      _SettingsCategory(
        label: '关于',
        description: '版本与开源信息',
        icon: Icons.info_outline_rounded,
        path: '/settings/about',
        color: Color(0xFF8E8E93),
      ),
    ],
  ),
];

String _normalizePath(String path) =>
    path.endsWith('/') ? path.substring(0, path.length - 1) : path;

bool _isWithinPath(String location, String path) =>
    location == path || location.startsWith('$path/');

String _categoryPath(String location) {
  if (location == '/settings') {
    return '/settings/player';
  }
  if (_isWithinPath(location, '/settings/bangumi') ||
      _isWithinPath(location, '/settings/webdav')) {
    return '/settings/sync';
  }
  for (final group in _settingsGroups) {
    for (final category in group.categories) {
      if (_isWithinPath(location, category.path)) {
        return category.path;
      }
    }
  }
  return location;
}

class _SettingsCategorySelected extends Notification {
  const _SettingsCategorySelected(this.path);

  final String path;
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.location});

  final String location;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _outletKey = GlobalKey<RouterOutletState>();
  Object? _categoryNavigation;
  late String _location = _normalizePath(widget.location);

  String get _selectedCategoryPath => _categoryPath(_location);
  bool get _isSecondaryRoute =>
      _location != '/settings' && _location != _selectedCategoryPath;

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) {
      _categoryNavigation = null;
      _location = _normalizePath(widget.location);
    }
  }

  void _replaceCategory(String path) {
    final outlet = _outletKey.currentState!;
    // Nested pushes leave _location unchanged, so check the stack as well.
    if (!outlet.canPop &&
        !_isSecondaryRoute &&
        _selectedCategoryPath == path) {
      return;
    }
    _categoryNavigation = null;
    outlet.navigate(path);
    setState(() => _location = path);
  }

  Future<void> _pushCategory(String path) async {
    if (_categoryNavigation != null) return;
    final navigation = Object();
    final previousLocation = _location;
    _categoryNavigation = navigation;
    setState(() => _location = path);
    await _outletKey.currentState!.push<void>(path);
    // Ignore completions from history replaced by a rail selection.
    if (!mounted || _categoryNavigation != navigation) return;
    setState(() {
      _categoryNavigation = null;
      _location = previousLocation;
    });
  }

  void _goBack() {
    if (_outletKey.currentState?.maybePop() ?? false) return;
    _exitSettings();
  }

  void _exitSettings() {
    if (!context.maybePop()) context.navigate('/tab/my');
  }

  @override
  Widget build(BuildContext context) {
    final palette = MonoPalette.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth > LayoutBreakpoint.compact['width']!;
      return NavigatorPopHandler<Object?>(
        onPopWithResult: (_) => _goBack(),
        child: Scaffold(
          backgroundColor: palette.groupedBackground,
          body: SafeArea(
            top: false,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Keep the outlet at the same tree position on resize.
                SizedBox(
                  width: wide ? 320 : 0,
                  child: Offstage(
                    offstage: !wide,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SysAppBar(
                          title: const Text('设置'),
                          backgroundColor: palette.groupedBackground,
                          showWindowControls: false,
                          leading: IconButton(
                            tooltip: '返回',
                            onPressed: _exitSettings,
                            icon: const Icon(Icons.arrow_back_rounded),
                          ),
                        ),
                        Expanded(
                          child: _SettingsMenu(
                            wide: true,
                            selectedPath: _selectedCategoryPath,
                            onSelect: _replaceCategory,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (wide)
                  VerticalDivider(
                    width: 0.5,
                    thickness: 0.5,
                    color: palette.hairline,
                  ),
                Expanded(
                  child: SettingsPaneScope(
                    embedded: wide,
                    showBackButton: _isSecondaryRoute,
                    onBack: _goBack,
                    child: NotificationListener<_SettingsCategorySelected>(
                      onNotification: (notification) {
                        _pushCategory(notification.path);
                        return true;
                      },
                      child: Theme(
                        data: Theme.of(context).copyWith(
                          pageTransitionsTheme: settingsPageTransitionsTheme,
                        ),
                        child: RouterOutlet(key: _outletKey),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

class SettingsIndexPage extends StatelessWidget {
  const SettingsIndexPage({super.key});

  @override
  Widget build(BuildContext context) {
    if (SettingsPaneScope.of(context)?.embedded ?? false) {
      return const PlayerSettingsPage();
    }
    final background = MonoPalette.of(context).groupedBackground;
    return Scaffold(
      backgroundColor: background,
      appBar: SysAppBar(
        title: const Text('设置'),
        backgroundColor: background,
        contentWidth: (_) => settingsReadableWidth,
        leading: IconButton(
          tooltip: '返回',
          onPressed: () {
            if (!context.maybePop()) context.navigate('/tab/my');
          },
          icon: const Icon(Icons.arrow_back_rounded),
        ),
      ),
      body: _SettingsMenu(
        wide: false,
        onSelect: (path) => _SettingsCategorySelected(path).dispatch(context),
      ),
    );
  }
}

class _SettingsMenu extends StatelessWidget {
  const _SettingsMenu({
    required this.wide,
    this.selectedPath,
    required this.onSelect,
  });

  final bool wide;
  final String? selectedPath;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: MonoPalette.of(context).groupedBackground,
      child: MonoGroupedScope(
        grouped: true,
        child: ScrollConfiguration(
          behavior:
              ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              for (final group in _settingsGroups)
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                        maxWidth: settingsReadableWidth - 32),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 10),
                      child: ContentSection.group(
                        title: group.title,
                        children: [
                          for (final category in group.categories)
                            SettingsCategoryTile(
                              icon: category.icon,
                              color: category.color,
                              title: category.label,
                              // The sidebar keeps rows to one line.
                              description: wide ? '' : category.description,
                              selected: wide && selectedPath == category.path,
                              onTap: () => onSelect(category.path),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
