import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/my/watch_stats.dart';
import 'package:kazumi/pages/my/my_space_view.dart';

void main() {
  testWidgets('every settings page opens straight from 我的', (tester) async {
    tester.view.physicalSize = const Size(390, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final opened = <MyDestination>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MySpaceView(stats: const WatchStats(), onOpen: opened.add),
        ),
      ),
    );
    for (final title in ['界面设置', '操作设置', '下载设置', '网络设置', '更新设置']) {
      await tester.tap(find.text(title));
    }
    expect(opened, [
      MyDestination.interface,
      MyDestination.keyboard,
      MyDestination.downloadSettings,
      MyDestination.proxy,
      MyDestination.update,
    ]);
    expect(find.byTooltip('全部设置'), findsNothing);
  });
}
