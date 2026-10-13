import 'dart:convert';
import 'dart:ffi';

import 'package:dio/dio.dart';
import 'package:kazumi/request/clients/download_http_client.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/network_exception.dart';

enum InstallationType {
  windowsMsix,
  windowsPortable,
  linuxDeb,
  linuxTar,
  macosDmg,
  androidApk,
  ios,
  unknown,
}

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.description,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.publishedAt,
    this.fileName = '',
    this.installationType,
    this.availableInstallationTypes = const [],
    this.assets = const [],
  });

  final String version;
  final String description;
  final String downloadUrl;
  final String releaseNotes;
  final String publishedAt;
  final String fileName;
  final InstallationType? installationType;
  final List<InstallationType> availableInstallationTypes;
  final List<dynamic> assets;

  InstallationType get recommendedInstallationType =>
      availableInstallationTypes.firstOrNull ??
      installationType ??
      InstallationType.unknown;
}

typedef ReleaseMetadataLoader = Future<String> Function(Uri url);

String getUpdateDisplayVersion(String tag) =>
    tag.replaceFirst(RegExp(r'^(?:monogatari-v|v)'), '');

/// Public GitHub metadata is the single source of application updates.
class GitHubReleaseMetadata {
  GitHubReleaseMetadata({ReleaseMetadataLoader? load})
    : _load = load ?? _downloadText;

  final ReleaseMetadataLoader _load;

  static Future<String> _downloadText(Uri url) =>
      DownloadHttpClient.instance.getPlain(url.toString());

  Future<Map<String, dynamic>?> latest() async {
    final String raw;
    try {
      raw = await _load(Uri.parse(ApiEndpoints.latestAppApi));
    } on NetworkException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> ||
        decoded['tag_name'] is! String ||
        (decoded['tag_name'] as String).trim().isEmpty ||
        (decoded['assets'] != null && decoded['assets'] is! List)) {
      throw const FormatException('GitHub 发行版信息无效');
    }
    if (decoded['draft'] == true || decoded['prerelease'] == true) return null;
    return decoded;
  }
}

/// Ignore old mirror fields: every package opens or downloads from GitHub.
String getUpdateDownloadUrlFromAsset(Map<String, dynamic>? asset) {
  final value = asset?['browser_download_url'];
  if (value is! String) return '';
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.toLowerCase() != 'github.com' ||
      uri.userInfo.isNotEmpty) {
    return '';
  }
  return value;
}

String getUpdateFileHashFromAsset(Map<String, dynamic> asset) {
  final digest = asset['digest'];
  if (digest is! String || !digest.startsWith('sha256:')) return '';
  return digest.substring('sha256:'.length);
}

Map<String, dynamic>? getUpdateAssetForType(
  List<dynamic> assets,
  InstallationType type, {
  Abi? abi,
}) {
  final matches = assets
      .whereType<Map>()
      .map((asset) => Map<String, dynamic>.from(asset))
      .where((asset) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        if (getUpdateDownloadUrlFromAsset(asset).isEmpty) return false;
        return switch (type) {
          InstallationType.windowsMsix =>
            name.contains('windows') &&
                (name.endsWith('.msix') || name.endsWith('.msixbundle')),
          InstallationType.windowsPortable =>
            name.contains('windows') && name.endsWith('.zip'),
          InstallationType.androidApk =>
            name.contains('android') && name.endsWith('.apk'),
          InstallationType.ios => name.contains('ios') && name.endsWith('.ipa'),
          InstallationType.macosDmg =>
            name.contains('macos') && name.endsWith('.dmg'),
          InstallationType.linuxDeb =>
            name.contains('linux') && name.endsWith('.deb'),
          InstallationType.linuxTar =>
            name.contains('linux') &&
                (name.endsWith('.tar.gz') || name.endsWith('.tar.xz')),
          InstallationType.unknown => false,
        };
      })
      .toList();
  if (type != InstallationType.androidApk) return matches.firstOrNull;
  final architecture = switch (abi ?? Abi.current()) {
    Abi.androidArm64 => 'arm64',
    Abi.androidArm => 'armv7',
    Abi.androidX64 => 'x64',
    Abi.androidIA32 => 'x86',
    _ => null,
  };
  if (architecture == null) return null;
  for (final asset in matches) {
    if (_androidArchitecture(asset['name'] as String) == architecture) {
      return asset;
    }
  }
  final universal = matches
      .where(
        (asset) => RegExp(
          r'(^|[-_.])universal([-_.]|$)',
          caseSensitive: false,
        ).hasMatch(asset['name'] as String),
      )
      .firstOrNull;
  if (universal != null) return universal;
  // Older Kazumi_android_<version>.apk releases were ARM64-only. A filename
  // without an ABI must never be assumed compatible with an x64 emulator.
  if (architecture == 'arm64') {
    return matches
        .where(
          (asset) => RegExp(
            r'^kazumi[_-]android[_-]\d+\.\d+\.\d+\.apk$',
            caseSensitive: false,
          ).hasMatch(asset['name'] as String),
        )
        .firstOrNull;
  }
  return null;
}

String? _androidArchitecture(String name) {
  final lower = name.toLowerCase();
  if (RegExp(r'arm64|aarch64').hasMatch(lower)) return 'arm64';
  if (RegExp(r'armv7|armeabi-v7a|arm-v7').hasMatch(lower)) return 'armv7';
  if (RegExp(r'x86_64|x64|amd64').hasMatch(lower)) return 'x64';
  if (RegExp(r'(^|[-_.])x86([-_.]|$)').hasMatch(lower)) return 'x86';
  return null;
}

List<InstallationType> getAvailableUpdateInstallationTypes(
  List<dynamic> assets, {
  required String operatingSystem,
  Abi? abi,
}) {
  final preferred = switch (operatingSystem) {
    'windows' => [
      InstallationType.windowsMsix,
      InstallationType.windowsPortable,
    ],
    'android' => [InstallationType.androidApk],
    'ios' => [InstallationType.ios],
    'macos' => [InstallationType.macosDmg],
    'linux' => [InstallationType.linuxDeb, InstallationType.linuxTar],
    _ => <InstallationType>[],
  };
  return [
    for (final type in preferred)
      if (getUpdateAssetForType(assets, type, abi: abi) != null) type,
  ];
}
