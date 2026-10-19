import 'package:flutter/material.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/utils/theme.dart';

class SettingsPaneScope extends InheritedWidget {
  const SettingsPaneScope({
    super.key,
    required this.embedded,
    required this.showBackButton,
    required this.onBack,
    required super.child,
  });

  final bool embedded;
  final bool showBackButton;
  final VoidCallback onBack;

  static SettingsPaneScope? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<SettingsPaneScope>();
  }

  @override
  bool updateShouldNotify(SettingsPaneScope oldWidget) {
    return embedded != oldWidget.embedded ||
        showBackButton != oldWidget.showBackButton ||
        onBack != oldWidget.onBack;
  }
}

/// A settings page: large title over the grey grouped backdrop, as in the
/// iOS settings of the Monogatari apps.
class SettingsDetailScaffold extends StatelessWidget {
  const SettingsDetailScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.leading,
    this.floatingActionButton,
    this.bottomNavigationBar,
  });

  final Widget title;
  final Widget body;
  final List<Widget>? actions;
  final Widget? leading;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;

  @override
  Widget build(BuildContext context) {
    final scope = SettingsPaneScope.of(context);
    final background = MonoPalette.of(context).groupedBackground;
    final PreferredSizeWidget appBar;

    if (scope != null && scope.embedded) {
      final paneLeading = leading ??
          ((scope.showBackButton ||
                  (ModalRoute.of(context)?.impliesAppBarDismissal ?? false))
              ? IconButton(
                  tooltip: '返回',
                  onPressed: scope.onBack,
                  icon: const Icon(Icons.arrow_back_rounded),
                )
              : null);
      appBar = SysAppBar(
        title: title,
        actions: actions,
        leading: paneLeading,
        backgroundColor: background,
        contentWidth: _readableWidth,
        needTopOffset: false,
      );
    } else {
      appBar = SysAppBar(
        title: title,
        actions: actions,
        backgroundColor: background,
        contentWidth: _readableWidth,
        leading: leading ??
            (scope == null
                ? null
                : IconButton(
                    tooltip: '返回',
                    onPressed: scope.onBack,
                    icon: const Icon(Icons.arrow_back_rounded),
                  )),
      );
    }

    // Keep routed panes opaque during transitions.
    return Scaffold(
      backgroundColor: background,
      appBar: appBar,
      body: body,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
    );
  }
}

double _readableWidth(double _) => settingsReadableWidth;
