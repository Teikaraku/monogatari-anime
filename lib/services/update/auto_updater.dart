import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/update/github_release_metadata.dart';
import 'package:kazumi/services/update/startup_update_check.dart';
import 'package:kazumi/services/update/update_package_downloader.dart';
import 'package:kazumi/services/update/windows_update_installer.dart';
import 'package:kazumi/utils/date_time.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/utils/version.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';

export 'github_release_metadata.dart';

class AutoUpdater {
  AutoUpdater._internal();
  static final AutoUpdater _instance = AutoUpdater._internal();
  factory AutoUpdater() => _instance;

  final _metadata = GitHubReleaseMetadata();
  final _startupCheck = StartupUpdateCheck();
  final _packageDownloader = UpdatePackageDownloader();
  final _downloadDialogs = KazumiDialogController();
  final _downloadProgress = ValueNotifier<double?>(null);
  bool _hasPublicRelease = false;
  bool _installing = false;
  bool _updateDialogOpen = false;
  Future<UpdateInfo?>? _checkInFlight;

  Future<UpdateInfo?> checkForUpdates() {
    final pending = _checkInFlight;
    if (pending != null) return pending;
    late final Future<UpdateInfo?> check;
    check = _checkLatestRelease().whenComplete(() {
      if (identical(_checkInFlight, check)) _checkInFlight = null;
    });
    _checkInFlight = check;
    return check;
  }

  Future<UpdateInfo?> _checkLatestRelease() async {
    final data = await _metadata.latest();
    _hasPublicRelease = data != null;
    if (data == null) return null;
    final remoteVersion = data['tag_name'] as String;
    if (!needUpdate(ApiEndpoints.version, remoteVersion)) return null;
    final assets = data['assets'] as List? ?? const [];
    final types = getAvailableUpdateInstallationTypes(
      assets,
      operatingSystem: Platform.operatingSystem,
    );
    return UpdateInfo(
      version: getUpdateDisplayVersion(remoteVersion),
      description: data['body'] as String? ?? '发现新版本',
      downloadUrl: '',
      releaseNotes: data['html_url'] as String? ?? ApiEndpoints.latestApp,
      publishedAt: data['published_at'] as String? ?? '',
      installationType: types.firstOrNull,
      availableInstallationTypes: types,
      assets: assets,
    );
  }

  Future<void> autoCheckForUpdates() async {
    try {
      await _startupCheck.run(
        shouldRetry: (error) =>
            error is NetworkException &&
            const {
              NetworkExceptionType.connectionError,
              NetworkExceptionType.connectionTimeout,
              NetworkExceptionType.receiveTimeout,
              NetworkExceptionType.sendTimeout,
            }.contains(error.type),
        checkForUpdate: () async {
          final update = await checkForUpdates();
          if (update != null) await _showUpdateDialog(update);
        },
      );
    } catch (error) {
      KazumiLogger().w(
        'Update: automatic GitHub check failed after retry',
        error: error,
      );
    }
  }

  Future<void> manualCheckForUpdates() async {
    try {
      final update = await checkForUpdates();
      if (update != null) {
        await _showUpdateDialog(update);
      } else {
        KazumiDialog.showToast(
          message: _hasPublicRelease ? '当前已经是最新版本' : '暂无可用更新',
        );
      }
    } catch (error) {
      KazumiLogger().w('Update: manual GitHub check failed', error: error);
      KazumiDialog.showToast(message: '检查更新失败，请稍后重试');
    }
  }

  Future<void> _showUpdateDialog(UpdateInfo update) async {
    if (_updateDialogOpen) return;
    _updateDialogOpen = true;
    final types = update.availableInstallationTypes;
    try {
      await KazumiDialog.show<void>(
        builder: (context) => AlertDialog(
          title: Text('发现新版本 ${update.version}'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(update.description),
                if (update.publishedAt.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '发布时间: ${formatDate(update.publishedAt)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (Platform.isIOS) ...[
                  const SizedBox(height: 12),
                  const Text('下载 IPA 后需要自行签名安装。'),
                ],
                if (types.isEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    Platform.isIOS
                        ? '此发行版暂未提供 iOS 安装包。'
                        : '此发行版暂未提供适合当前设备的安装包。',
                  ),
                ] else if (types.length > 1) ...[
                  const SizedBox(height: 12),
                  const Text('可用安装类型'),
                  for (final type in types)
                    TextButton.icon(
                      icon: const Icon(Icons.download_rounded),
                      label: Text(_installationDescription(type)),
                      onPressed: () {
                        KazumiDialog.dismiss();
                        _downloadUpdateWithType(update, type);
                      },
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => KazumiDialog.dismiss(),
              child: const Text('稍后提醒'),
            ),
            TextButton(
              onPressed: () => _openReleasePage(update),
              child: const Text('查看详情'),
            ),
            TextButton(
              onPressed: () {
                KazumiDialog.dismiss();
                if (types.isEmpty) {
                  _openReleasePage(update);
                } else {
                  _downloadUpdateWithType(update, types.first);
                }
              },
              child: Text(types.isEmpty ? '前往发行页面' : '立即更新'),
            ),
          ],
        ),
      );
    } finally {
      _updateDialogOpen = false;
    }
  }

  String _installationDescription(InstallationType type) => switch (type) {
    InstallationType.windowsMsix => 'Windows MSIX 包',
    InstallationType.windowsPortable => 'Windows 便携版 (ZIP)',
    InstallationType.linuxDeb => 'Linux DEB 包',
    InstallationType.linuxTar => 'Linux TAR 包',
    InstallationType.macosDmg => 'macOS DMG 镜像',
    InstallationType.androidApk => 'Android APK',
    InstallationType.ios => 'iOS IPA（自行签名）',
    InstallationType.unknown => '安装包',
  };

  Future<void> _openReleasePage(UpdateInfo update) async {
    final uri = Uri.tryParse(update.releaseNotes);
    await _openGitHub(
      uri != null && uri.scheme == 'https' && uri.host == 'github.com'
          ? uri
          : Uri.parse(ApiEndpoints.latestApp),
    );
  }

  Future<void> _openGitHub(Uri uri) async {
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        KazumiDialog.showToast(message: '无法打开 GitHub 下载页面');
      }
    } catch (error) {
      KazumiLogger().w('Update: failed to open GitHub page', error: error);
      KazumiDialog.showToast(message: '无法打开 GitHub 下载页面');
    }
  }

  Future<void> _downloadUpdateWithType(
    UpdateInfo update,
    InstallationType type,
  ) async {
    final asset = getUpdateAssetForType(update.assets, type);
    final url = getUpdateDownloadUrlFromAsset(asset);
    if (asset == null || url.isEmpty) {
      KazumiDialog.showToast(
        message: '此发行版没有可用的${_installationDescription(type)}',
      );
      return;
    }
    if (type == InstallationType.ios ||
        type == InstallationType.linuxDeb ||
        type == InstallationType.linuxTar) {
      // iOS downloads the selected release's IPA in the browser for self-signing.
      await _openGitHub(Uri.parse(url));
      return;
    }
    final downloadable = UpdateInfo(
      version: update.version,
      description: update.description,
      downloadUrl: url,
      fileName: asset['name'] as String,
      releaseNotes: update.releaseNotes,
      publishedAt: update.publishedAt,
      installationType: type,
      availableInstallationTypes: [type],
      assets: update.assets,
    );
    await _downloadUpdate(downloadable, getUpdateFileHashFromAsset(asset));
  }

  Future<void> _downloadUpdate(UpdateInfo update, String expectedHash) async {
    if (_downloadDialogs.isRunning) return;
    await _downloadDialogs.run(
      (task) async {
        _downloadProgress.value = null;
        final token = CancelToken();
        final filePath = await task.loading(
          action: () async {
            final path = await _packageDownloader.download(
              urls: [Uri.parse(update.downloadUrl)],
              fileName: update.fileName,
              sha256: expectedHash.isEmpty ? null : expectedHash,
              cancelToken: token,
              onProgress: (received, total) {
                if (!token.isCancelled) {
                  _downloadProgress.value = total > 0
                      ? (received / total).clamp(0.0, 1.0)
                      : null;
                }
              },
            );
            _downloadProgress.value = 1;
            return path;
          },
          onCancel: token.cancel,
          builder: (context) => AlertDialog(
            title: const Text('正在下载更新'),
            content: ValueListenableBuilder<double?>(
              valueListenable: _downloadProgress,
              builder: (_, value, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: value),
                  const SizedBox(height: 8),
                  Text(
                    value == null
                        ? '正在下载…'
                        : '${(value * 100).toStringAsFixed(1)}%',
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => KazumiDialog.dismiss(context: context),
                child: const Text('取消'),
              ),
            ],
          ),
        );
        _showDownloadCompleteDialog(filePath, update);
      },
      onError: (error, _) {
        KazumiLogger().e('Update: package download failed', error: error);
        KazumiDialog.show<void>(
          builder: (context) => AlertDialog(
            title: const Text('下载失败'),
            content: Text(error.toString()),
            actions: [
              TextButton(
                onPressed: () => KazumiDialog.dismiss(context: context),
                child: const Text('确定'),
              ),
              TextButton(
                onPressed: () {
                  KazumiDialog.dismiss(context: context);
                  _downloadUpdate(update, expectedHash);
                },
                child: const Text('重试'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showDownloadCompleteDialog(String filePath, UpdateInfo update) {
    KazumiDialog.show<void>(
      builder: (context) => AlertDialog(
        title: const Text('下载完成'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('新版本 ${update.version} 已下载并验证'),
            const SizedBox(height: 12),
            Text(
              Platform.isAndroid
                  ? '点击安装后将打开系统安装器，请按提示完成更新。'
                  : '安装时应用将退出，完成后会重新启动。',
            ),
            const SizedBox(height: 12),
            SelectableText(
              filePath,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(context: context),
            child: const Text('稍后安装'),
          ),
          if (isDesktop())
            TextButton(
              onPressed: () => _revealInFileManager(filePath),
              child: const Text('打开文件夹'),
            ),
          TextButton(
            onPressed: () {
              KazumiDialog.dismiss(context: context);
              _installUpdate(filePath, update.recommendedInstallationType);
            },
            child: const Text('立即安装'),
          ),
        ],
      ),
    );
  }

  Future<void> _installUpdate(String filePath, InstallationType type) async {
    if (_installing) return;
    _installing = true;
    try {
      if (Platform.isWindows && type == InstallationType.windowsPortable) {
        final prepared = await WindowsUpdateInstaller().prepare(
          packagePath: filePath,
        );
        await prepared.launch();
        exit(0);
      } else if (Platform.isWindows && type == InstallationType.windowsMsix) {
        if (!await launchUrl(Uri.file(filePath))) {
          throw const FileSystemException('无法打开系统安装器');
        }
        exit(0);
      } else if (Platform.isAndroid) {
        final result = await OpenFilex.open(filePath);
        if (result.type != ResultType.done) {
          throw FileSystemException('无法打开系统安装器: ${result.message}');
        }
      } else if (Platform.isMacOS && type == InstallationType.macosDmg) {
        await Process.start('open', [filePath]);
        exit(0);
      }
    } catch (error) {
      KazumiLogger().e('Update: launch installer failed', error: error);
      KazumiDialog.showToast(message: '启动安装程序失败，请重试');
    } finally {
      _installing = false;
    }
  }

  Future<void> _revealInFileManager(String filePath) async {
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', [
          '/select,${filePath.replaceAll('/', r'\')}',
        ]);
      } else if (Platform.isMacOS) {
        await Process.start('open', ['-R', filePath]);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [File(filePath).parent.path]);
      }
    } catch (error) {
      KazumiLogger().w('Update: reveal package failed', error: error);
      KazumiDialog.showToast(message: '无法打开文件管理器');
    }
  }
}
