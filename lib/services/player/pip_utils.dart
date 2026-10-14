import 'dart:io';

import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/desktop_pip_geometry.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/utils/device.dart';

class PipUtils {
  static bool androidPIPInited = false;

  // 比例约分
  static Size getPIPAspectSize({required int width, required int height}) {
    if (width <= 0 || height <= 0) {
      return const Size(16, 9);
    }
    final int divisor = width.gcd(height);
    return Size(width / divisor, height / divisor);
  }

  static Future<bool> isAndroidPIPSupported() async {
    if (!Platform.isAndroid) {
      return false;
    }
    const pipChannel = MethodChannel('com.predidit.kazumi/pip');
    try {
      final bool? supported =
          await pipChannel.invokeMethod('isPictureInPictureSupported');
      return supported ?? false;
    } on PlatformException catch (e) {
      KazumiLogger().e("Failed to check Android PIP support: '${e.message}'.");
      return false;
    }
  }

  static Future<bool> enterAndroidPIPWindow(
      {int width = 16, int height = 9}) async {
    if (!Platform.isAndroid) {
      return false;
    }
    final Size aspectSize = getPIPAspectSize(width: width, height: height);
    const pipChannel = MethodChannel('com.predidit.kazumi/pip');
    try {
      final bool? entered =
          await pipChannel.invokeMethod('enterPictureInPictureMode', {
        'width': aspectSize.width.toInt(),
        'height': aspectSize.height.toInt(),
      });
      return entered ?? false;
    } on PlatformException catch (e) {
      KazumiLogger().e("Failed to enter Android PIP mode: '${e.message}'.");
      return false;
    }
  }

  static Future<void> updateAndroidPIPActions({
    required bool playing,
    required bool danmakuEnabled,
    int width = 16,
    int height = 9,
    Rect? sourceRect,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }
    final Size aspectSize = getPIPAspectSize(width: width, height: height);
    const pipChannel = MethodChannel('com.predidit.kazumi/pip');
    try {
      await pipChannel.invokeMethod('updatePictureInPictureActions', {
        'playing': playing,
        'danmakuEnabled': danmakuEnabled,
        'width': aspectSize.width.toInt(),
        'height': aspectSize.height.toInt(),
        if (sourceRect != null) ...{
          'sourceLeft': sourceRect.left.round(),
          'sourceTop': sourceRect.top.round(),
          'sourceRight': sourceRect.right.round(),
          'sourceBottom': sourceRect.bottom.round(),
        },
      });
    } on PlatformException catch (e) {
      KazumiLogger().e("Failed to update Android PIP actions: '${e.message}'.");
    }
  }

  static Future<void> setAndroidAutoEnterPIPEnabled(bool enabled) async {
    if (!Platform.isAndroid) {
      return;
    }
    const pipChannel = MethodChannel('com.predidit.kazumi/pip');
    try {
      await pipChannel.invokeMethod('setAndroidAutoEnterPIPEnabled', {
        'enabled': enabled,
      });
    } on PlatformException catch (e) {
      KazumiLogger().e(
          "Failed to set Android auto-enter PIP enabled state: '${e.message}'.");
    }
  }

  static Future<void> setAndroidPIPInPlayerPage(bool inPlayerPage) async {
    if (!Platform.isAndroid) {
      return;
    }
    const pipChannel = MethodChannel('com.predidit.kazumi/pip');
    try {
      await pipChannel.invokeMethod('setAndroidPIPInPlayerPage', {
        'inPlayerPage': inPlayerPage,
      });
    } on PlatformException catch (e) {
      KazumiLogger().e("Failed to set Android PIP page state: '${e.message}'.");
    }
  }

  // The window before desktop PiP, restored on exit.
  static ({Rect bounds, bool maximized, bool alwaysOnTop})? _desktopRestore;
  static Future<void> _desktopPipTask = Future.value();

  // Window calls interleave across awaits, so run one transition at a time.
  static Future<void> _runDesktopPipTask(Future<void> Function() task) {
    final next = _desktopPipTask.catchError((_) {}).then((_) => task());
    _desktopPipTask = next;
    return next;
  }

  static Future<List<Rect>> _desktopWorkAreas() async {
    try {
      return [
        for (final display in await screenRetriever.getAllDisplays())
          (display.visiblePosition ?? Offset.zero) &
              (display.visibleSize ?? display.size),
      ];
    } catch (e) {
      KazumiLogger().w('PipUtils: failed to read displays', error: e);
      return const [];
    }
  }

  // 进入桌面设备小窗模式，并用播放源比例固定窗口宽高比
  static Future<void> enterDesktopPIPWindow(
          {int width = 16, int height = 9}) =>
      _runDesktopPipTask(() async {
        final Size aspectSize = getPIPAspectSize(width: width, height: height);
        final double aspectRatio = aspectSize.width / aspectSize.height;
        final workAreas = await _desktopWorkAreas();
        final Rect target;
        if (_desktopRestore == null) {
          final maximized = await windowManager.isMaximized();
          if (maximized) {
            await windowManager.unmaximize();
            // Windows applies the restore asynchronously.
            for (var i = 0; i < 20 && await windowManager.isMaximized(); i++) {
              await Future<void>.delayed(const Duration(milliseconds: 25));
            }
          }
          final bounds = await windowManager.getBounds();
          _desktopRestore = (
            bounds: bounds,
            maximized: maximized,
            alwaysOnTop: await windowManager.isAlwaysOnTop(),
          );
          target = DesktopPipGeometry.initial(
            aspectRatio: aspectRatio,
            window: bounds,
            workAreas: workAreas,
            saved: GStorage.getSetting(SettingsKeys.desktopPipWindow),
          );
        } else {
          // A new video size only changes the height of the open PiP window.
          final current = await windowManager.getBounds();
          final resized = Rect.fromLTWH(current.left, current.top,
              current.width, current.width / aspectRatio);
          final area = DesktopPipGeometry.workAreaFor(resized.center, workAreas);
          target =
              area == null ? resized : DesktopPipGeometry.fit(resized, area);
        }
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setAspectRatio(aspectRatio);
        await windowManager.setBounds(target);
      });

  // 退出桌面设备小窗模式
  static Future<void> exitDesktopPIPWindow() => _runDesktopPipTask(() async {
        final restore = _desktopRestore;
        _desktopRestore = null;
        await windowManager.setAspectRatio(0);
        if (restore == null) {
          final lowResolution = await isLowResolution();
          await windowManager.setAlwaysOnTop(false);
          await windowManager.setSize(
              lowResolution ? const Size(800, 600) : const Size(1280, 860));
          await windowManager.center();
          return;
        }
        final pip = await windowManager.getBounds();
        await GStorage.putSetting<List<dynamic>>(
            SettingsKeys.desktopPipWindow, [pip.left, pip.top, pip.width]);
        await windowManager.setAlwaysOnTop(restore.alwaysOnTop);
        await windowManager.setBounds(restore.bounds);
        if (restore.maximized) await windowManager.maximize();
      });

  static void initPipHandler({
    required Future<void> Function(String action) onAction,
    required void Function(bool inPipMode) onModeChanged,
  }) {
    const MethodChannel pipChannel = MethodChannel('com.predidit.kazumi/pip');
    if (androidPIPInited) return;
    androidPIPInited = true;

    pipChannel.setMethodCallHandler((call) async {
      if (!Platform.isAndroid) {
        return;
      }

      final Object? args = call.arguments;
      final Map? arguments = (args is Map) ? args : null;

      switch (call.method) {
        case 'onModeChanged':
          final bool? inPipMode = arguments?['isInPipMode'] as bool?;
          if (inPipMode != null) {
            onModeChanged(inPipMode);
          }
        case 'onAction':
          final String? action = arguments?['action'] as String?;
          if (action != null) {
            await onAction(action);
          }
      }
    });
  }

  static void disposePipHandler() {
    const MethodChannel pipChannel = MethodChannel('com.predidit.kazumi/pip');
    pipChannel.setMethodCallHandler(null);
    androidPIPInited = false;
  }
}
