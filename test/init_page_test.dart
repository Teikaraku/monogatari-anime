import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/init_page.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/danmaku_shield_sync_service.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  late Directory directory;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp(
      'monogatari_startup_test_',
    );
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
    await GStorage.putSetting(SettingsKeys.defaultStartupPage, '/ready');
    await GStorage.putSetting(SettingsKeys.shortcutDialogShown, true);
    // Even an old rule-update preference must no longer trigger rule loading.
    await GStorage.putSetting(SettingsKeys.checkPluginUpdateOnStartup, true);
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    expect(
      directory.absolute.path.startsWith(Directory.systemTemp.absolute.path),
      isTrue,
    );
    expect(
      directory.uri.pathSegments.where((part) => part.isNotEmpty).last,
      startsWith('monogatari_startup_test_'),
    );
    await directory.delete(recursive: true);
  });

  testWidgets('launch opens the default page without initializing rules', (
    tester,
  ) async {
    final myController = _TestMyController();
    await tester.runAsync(() async {
      await _pumpStartup(tester, myController);
      await _pumpUntil(
        tester,
        () => find.text('Ready to watch').evaluate().isNotEmpty,
      );
      await _pumpUntil(tester, () => myController.updateChecks == 1);
    });
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(InitPage), findsNothing);
    expect(find.text('继续'), findsNothing);
    expect(find.text('开始使用'), findsNothing);
    final rulesDirectoryExists = await tester.runAsync(
      () => Directory('${directory.path}/plugins').exists(),
    );
    expect(rulesDirectoryExists, isFalse);
    expect(GStorage.getSetting(SettingsKeys.autoUpdate), isTrue);
    expect(myController.updateChecks, 1);
    expect(BangumiAcceleration.current, BangumiAcceleration.mirror);
    expect(GStorage.getSetting(SettingsKeys.imageAcceleration), 'mirror');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    final legacyRules = File('${directory.path}/plugins/v2/plugins.json');
    final nextMyController = _TestMyController();

    await tester.runAsync(() async {
      await GStorage.putSetting(SettingsKeys.autoUpdate, false);
      await legacyRules.parent.create(recursive: true);
      await legacyRules.writeAsString('legacy rules remain untouched');
      await _pumpStartup(tester, nextMyController);
      await _pumpUntil(
        tester,
        () => find.text('Ready to watch').evaluate().isNotEmpty,
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(milliseconds: 600));
    final legacyRulesContent = await tester.runAsync(legacyRules.readAsString);
    expect(legacyRulesContent, 'legacy rules remain untouched');
    expect(nextMyController.updateChecks, 0);
    expect(GStorage.getSetting(SettingsKeys.autoUpdate), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

Future<void> _pumpStartup(
  WidgetTester tester,
  MyController myController,
) async {
  final module = createModule(
    register: (c) {
      c
        ..route(
          '/',
          child: (context, state) => InitPage(
            collectController: _TestCollectController(),
            shaderAssetService: _TestShaderService(),
            myController: myController,
            downloadController: _TestDownloadController(),
            danmakuShieldSync: _TestShieldSync(),
          ),
        )
        ..route(
          '/ready',
          child: (context, state) =>
              const Scaffold(body: Text('Ready to watch')),
        );
    },
  );
  await tester.pumpWidget(
    ModularApp(
      module: module,
      child: Builder(
        builder: (context) => MaterialApp.router(
          routerConfig: ModularApp.routerConfigOf(context),
        ),
      ),
    ),
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var frame = 0; frame < 100 && !ready(); frame++) {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await tester.pump();
  expect(ready(), isTrue);
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _TestMyController implements MyController {
  int updateChecks = 0;

  @override
  Future<bool> checkUpdate({String type = 'manual'}) async {
    updateChecks++;
    return true;
  }

  @override
  Future<void> loadShieldList() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestCollectController implements CollectController {
  @override
  Future<void> migrateCollect() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestShaderService implements ShaderAssetService {
  @override
  Future<void> copyShadersToExternalDirectory() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestDownloadController implements DownloadController {
  @override
  Future<void> init() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestShieldSync implements DanmakuShieldSyncService {
  @override
  void start() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
