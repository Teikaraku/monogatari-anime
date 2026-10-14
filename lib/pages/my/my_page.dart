import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/pages/menu/route_visibility.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/pages/my/my_space_view.dart';
import 'package:kazumi/utils/theme.dart';

class MyPage extends StatefulWidget {
  const MyPage({super.key, required this.controller});

  final MyController controller;

  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  bool _attached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _setAttached(!RouteVisibility.isCoveredOf(context));
  }

  @override
  void didUpdateWidget(covariant MyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_attached && oldWidget.controller != widget.controller) {
      oldWidget.controller.detach();
      widget.controller.attach();
    }
  }

  @override
  void dispose() {
    _setAttached(false);
    super.dispose();
  }

  void _setAttached(bool value) {
    if (_attached == value) return;
    _attached = value;
    if (value) {
      widget.controller.attach();
    } else {
      widget.controller.detach();
    }
  }

  void _open(MyDestination destination) =>
      context.pushNamed(switch (destination) {
        MyDestination.theme => '/settings/theme',
        MyDestination.interface => '/settings/interface',
        MyDestination.player => '/settings/player',
        MyDestination.danmaku => '/settings/danmaku/',
        MyDestination.keyboard => '/settings/keyboard',
        MyDestination.downloadSettings => '/settings/download-settings',
        MyDestination.history => '/settings/history/',
        MyDestination.downloads => '/settings/download/',
        MyDestination.subscriptions => '/subscriptions/',
        MyDestination.torrentTasks => '/torrent-tasks/',
        MyDestination.stats => '/settings/history/stats',
        MyDestination.sync => '/settings/sync',
        MyDestination.proxy => '/settings/proxy/',
        MyDestination.update => '/settings/update',
        MyDestination.storage => '/settings/storage',
        MyDestination.about => '/settings/about/',
      });

  @override
  Widget build(BuildContext context) {
    final background = MonoPalette.of(context).groupedBackground;
    return Scaffold(
      backgroundColor: background,
      appBar: SysAppBar(
        title: const Text('我的'),
        needTopOffset: false,
        backgroundColor: background,
        contentWidth: MySpaceView.contentWidthFor,
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Observer(
          builder: (context) =>
              MySpaceView(stats: widget.controller.watchStats, onOpen: _open),
        ),
      ),
    );
  }
}
