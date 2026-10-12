import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/widget/embedded_native_control_area.dart';
import 'package:kazumi/services/platform/desktop_window_config.dart';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/utils/device.dart';

/// Page header in the Monogatari style: a row of tinted actions with the page
/// name as a large title underneath. Without a title, or with [largeTitle]
/// off, it is a plain toolbar.
class SysAppBar extends StatelessWidget implements PreferredSizeWidget {
  final double? toolbarHeight;
  final Widget? title;
  final Color? backgroundColor;
  final List<Widget>? actions;
  final Widget? leading;
  final bool needTopOffset;
  final bool largeTitle;

  /// Adds the close button of the custom desktop title bar; panes nested in
  /// a page that already shows it turn this off.
  final bool showWindowControls;

  /// Width of the centred content column below, side padding included; the
  /// large title lines up with it on wide windows.
  final double Function(double pageWidth)? contentWidth;

  /// Height of the action row above a large title.
  static const double actionRowHeight = 48;

  /// Height of the large title line, including its bottom padding.
  static const double largeTitleHeight = 52;

  const SysAppBar({
    super.key,
    this.toolbarHeight,
    this.title,
    this.backgroundColor,
    this.actions,
    this.leading,
    this.needTopOffset = true,
    this.largeTitle = true,
    this.showWindowControls = true,
    this.contentWidth,
  });

  bool get _large => largeTitle && title != null;

  double get _macOffset =>
      Platform.isMacOS && needTopOffset && DesktopWindowConfig.showWindowButton
          ? 22.0
          : 0.0;

  List<Widget> _actions() {
    final appBarActions = <Widget>[...?actions];
    if (isDesktop() && showWindowControls) {
      if (!DesktopWindowConfig.showWindowButton) {
        appBarActions.add(CloseButton(onPressed: () => windowManager.close()));
      }
      appBarActions.add(const SizedBox(width: 4));
    }
    return appBarActions;
  }

  Widget? _leading(BuildContext context) =>
      leading ??
      ((ModalRoute.of(context)?.impliesAppBarDismissal ?? false)
          ? IconButton(
              tooltip: '返回',
              onPressed: () => context.maybePop(),
              icon: const Icon(Icons.arrow_back_rounded),
            )
          : null);

  SystemUiOverlayStyle _overlay(BuildContext context) => SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Theme.of(context).brightness == Brightness.light
            ? Brightness.dark
            : Brightness.light,
        statusBarBrightness: Theme.of(context).brightness,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
      );

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktop();
    final appBarActions = _actions();
    final appBarLeading = _leading(context);

    if (!_large) {
      return GestureDetector(
        onPanStart: desktop ? (_) => windowManager.startDragging() : null,
        child: AppBar(
          toolbarHeight: preferredSize.height,
          title: title != null
              ? EmbeddedNativeControlArea(
                  requireOffset: needTopOffset,
                  child: title!,
                )
              : null,
          centerTitle: Platform.isIOS,
          actions: appBarActions.map((action) {
            return EmbeddedNativeControlArea(
              requireOffset: needTopOffset,
              child: action,
            );
          }).toList(),
          leading: appBarLeading != null
              ? EmbeddedNativeControlArea(
                  requireOffset: needTopOffset,
                  child: appBarLeading,
                )
              : null,
          backgroundColor: backgroundColor,
          automaticallyImplyLeading: false,
          systemOverlayStyle: _overlay(context),
        ),
      );
    }

    final theme = Theme.of(context);
    final iconColor = theme.appBarTheme.actionsIconTheme?.color ??
        theme.colorScheme.primary;
    final background = backgroundColor ?? theme.scaffoldBackgroundColor;
    final titleStyle = theme.textTheme.headlineLarge?.copyWith(
      fontSize: 34,
      height: 1.2,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.2,
      color: theme.colorScheme.onSurface,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _overlay(context),
      child: Material(
        color: background,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: desktop ? (_) => windowManager.startDragging() : null,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.only(top: _macOffset),
              child: IconTheme.merge(
                data: IconThemeData(color: iconColor),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: actionRowHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Row(
                          children: [
                            ?appBarLeading,
                            const Spacer(),
                            ...appBarActions,
                          ],
                        ),
                      ),
                    ),
                    SizedBox(
                      height: largeTitleHeight,
                      child: LayoutBuilder(builder: (context, constraints) {
                        final inset = contentWidth == null
                            ? 0.0
                            : ((constraints.maxWidth - contentWidth!(constraints.maxWidth)) / 2)
                                .clamp(0.0, double.infinity);
                        return Padding(
                          padding: EdgeInsets.fromLTRB(
                              20 + inset, 0, 20 + inset, 10),
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: AlignmentDirectional.centerStart,
                              child: DefaultTextStyle.merge(
                                style: titleStyle,
                                maxLines: 1,
                                child: Semantics(header: true, child: title!),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Size get preferredSize {
    if (_large) {
      return Size.fromHeight(actionRowHeight + largeTitleHeight + _macOffset);
    }
    // Reserve space for native macOS window controls.
    return Size.fromHeight((toolbarHeight ?? kToolbarHeight) + _macOffset);
  }
}
