import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/player/desktop_pip_geometry.dart';
import 'package:kazumi/services/player/pip_utils.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  const screen = Rect.fromLTWH(0, 0, 1920, 1040);
  const wide = 16 / 9;

  group('DesktopPipGeometry', () {
    test('opens in the bottom-right corner of the window\'s screen', () {
      const right = Rect.fromLTWH(1920, 0, 2560, 1400);
      expect(
        DesktopPipGeometry.initial(
          aspectRatio: wide,
          window: const Rect.fromLTWH(100, 100, 1280, 860),
          workAreas: [screen, right],
        ),
        const Rect.fromLTWH(1416, 746, 480, 270),
      );
      expect(
        DesktopPipGeometry.initial(
          aspectRatio: wide,
          window: const Rect.fromLTWH(2200, 200, 800, 600),
          workAreas: [screen, right],
        ),
        const Rect.fromLTWH(3976, 1106, 480, 270),
      );
    });

    test('reuses the remembered place while it is still on a screen', () {
      Rect open(List<dynamic> saved) => DesktopPipGeometry.initial(
            aspectRatio: wide,
            window: screen,
            workAreas: [screen],
            saved: saved,
          );
      expect(open([100.0, 80.0, 640.0]), const Rect.fromLTWH(100, 80, 640, 360));
      // A disconnected monitor or a malformed value falls back to the corner.
      expect(open([3000.0, 80.0, 640.0]), const Rect.fromLTWH(1416, 746, 480, 270));
      expect(open(['x', 80.0, 640.0]), const Rect.fromLTWH(1416, 746, 480, 270));
    });

    test('keeps the aspect ratio while fitting inside the work area', () {
      expect(
        DesktopPipGeometry.fit(const Rect.fromLTWH(1800, 900, 480, 270), screen),
        const Rect.fromLTWH(1440, 770, 480, 270),
      );
      final shrunk = DesktopPipGeometry.fit(
        const Rect.fromLTWH(0, 0, 1600, 900),
        const Rect.fromLTWH(0, 0, 800, 600),
      );
      expect(shrunk.width, 752);
      expect(shrunk.width / shrunk.height, closeTo(wide, 0.001));
    });
  });

  group('PipUtils desktop window', () {
    late Directory directory;
    late PathProviderPlatform originalPaths;
    late _FakeWindow window;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      Logger.level = Level.off;
      directory = await Directory.systemTemp.createTemp('monogatari_pip_test_');
      originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPaths(directory.path);
      Hive.init(directory.path);
      await GStorage.init();
    });

    tearDownAll(() async {
      await Hive.close();
      PathProviderPlatform.instance = originalPaths;
      await directory.delete(recursive: true);
    });

    setUp(() => window = _FakeWindow(screen)..install());
    tearDown(() => window.uninstall());

    test('restores a maximized window and remembers the PiP place', () async {
      await GStorage.putSetting(SettingsKeys.desktopPipWindow, <dynamic>[]);
      window
        ..bounds = const Rect.fromLTWH(200, 100, 1280, 860)
        ..maximized = true;

      await PipUtils.enterDesktopPIPWindow(width: 1920, height: 1080);
      expect(window.maximized, isFalse);
      expect(window.alwaysOnTop, isTrue);
      expect(window.bounds, const Rect.fromLTWH(1416, 746, 480, 270));

      // The user drags the PiP window elsewhere, then a new episode changes
      // the video size: only the height follows.
      window.bounds = const Rect.fromLTWH(60, 40, 640, 360);
      await PipUtils.enterDesktopPIPWindow(width: 4, height: 3);
      expect(window.bounds, const Rect.fromLTWH(60, 40, 640, 480));

      await PipUtils.exitDesktopPIPWindow();
      expect(window.alwaysOnTop, isFalse);
      expect(window.aspectRatio, 0);
      expect(window.bounds, const Rect.fromLTWH(200, 100, 1280, 860));
      expect(window.maximized, isTrue);
      expect(GStorage.getSetting(SettingsKeys.desktopPipWindow),
          [60.0, 40.0, 640.0]);

      window.maximized = false;
      await PipUtils.enterDesktopPIPWindow(width: 16, height: 9);
      expect(window.bounds, const Rect.fromLTWH(60, 40, 640, 360));
      await PipUtils.exitDesktopPIPWindow();
      expect(window.bounds, const Rect.fromLTWH(200, 100, 1280, 860));
      expect(window.maximized, isFalse);
    });
  });
}

/// Answers window_manager and screen_retriever like a single-screen desktop.
class _FakeWindow {
  _FakeWindow(this.workArea);

  final Rect workArea;
  Rect bounds = Rect.zero;
  bool maximized = false;
  bool alwaysOnTop = false;
  double aspectRatio = 0;

  static const _window = MethodChannel('window_manager');
  static const _screens =
      MethodChannel('dev.leanflutter.plugins/screen_retriever');

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install() {
    _messenger.setMockMethodCallHandler(_window, (call) async {
      final args = call.arguments is Map ? call.arguments as Map : const {};
      switch (call.method) {
        case 'isMaximized':
          return maximized;
        case 'maximize':
          maximized = true;
        case 'unmaximize':
          maximized = false;
        case 'isAlwaysOnTop':
          return alwaysOnTop;
        case 'setAlwaysOnTop':
          alwaysOnTop = args['isAlwaysOnTop'] as bool;
        case 'setAspectRatio':
          aspectRatio = (args['aspectRatio'] as num).toDouble();
        case 'getBounds':
          return {
            'x': bounds.left,
            'y': bounds.top,
            'width': bounds.width,
            'height': bounds.height,
          };
        case 'setBounds':
          bounds = Rect.fromLTWH(
            (args['x'] as num).toDouble(),
            (args['y'] as num).toDouble(),
            (args['width'] as num).toDouble(),
            (args['height'] as num).toDouble(),
          );
      }
      return null;
    });
    _messenger.setMockMethodCallHandler(_screens, (call) async {
      if (call.method != 'getAllDisplays') return null;
      return {
        'displays': [
          {
            'id': '1',
            'size': {'width': workArea.width, 'height': workArea.height + 40},
            'visiblePosition': {'dx': workArea.left, 'dy': workArea.top},
            'visibleSize': {'width': workArea.width, 'height': workArea.height},
            'scaleFactor': 1,
          },
        ],
      };
    });
  }

  void uninstall() {
    _messenger.setMockMethodCallHandler(_window, null);
    _messenger.setMockMethodCallHandler(_screens, null);
  }
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}
