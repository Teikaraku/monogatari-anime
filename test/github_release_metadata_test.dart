import 'dart:convert';
import 'dart:ffi';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/services/update/github_release_metadata.dart';
import 'package:kazumi/utils/version.dart';

void main() {
  group('GitHub release metadata', () {
    test('uses only the official repository latest release API', () async {
      final requests = <Uri>[];
      final source = GitHubReleaseMetadata(
        load: (url) async {
          requests.add(url);
          return jsonEncode({
            'tag_name': 'monogatari-v2.3.9',
            'assets': [_asset('Monogatari-Windows-x64.zip')],
          });
        },
      );

      final release = await source.latest();
      expect(requests, [Uri.parse(ApiEndpoints.latestAppApi)]);
      expect(requests.single.host, 'api.github.com');
      expect(release?['tag_name'], 'monogatari-v2.3.9');
    });

    test('official 404 is normal absence of a public release', () async {
      final source = GitHubReleaseMetadata(
        load: (_) async {
          throw const NetworkException(
            type: NetworkExceptionType.badResponse,
            message: 'Not Found',
            statusCode: 404,
          );
        },
      );
      expect(await source.latest(), isNull);
    });

    test('raw Dio 404 is also normal absence of a public release', () async {
      final source = GitHubReleaseMetadata(
        load: (_) async {
          final options = RequestOptions(path: ApiEndpoints.latestAppApi);
          throw DioException.badResponse(
            statusCode: 404,
            requestOptions: options,
            response: Response(requestOptions: options, statusCode: 404),
          );
        },
      );
      expect(await source.latest(), isNull);
    });

    for (final status in [403, 500]) {
      test(
        'HTTP $status remains a failure and is not reported as no update',
        () async {
          final source = GitHubReleaseMetadata(
            load: (_) async {
              throw NetworkException(
                type: NetworkExceptionType.badResponse,
                message: 'Failed',
                statusCode: status,
              );
            },
          );
          await expectLater(source.latest(), throwsA(isA<NetworkException>()));
        },
      );
    }

    test(
      'malformed successful responses are not treated as an up-to-date app',
      () async {
        for (final response in [
          '<html>bad gateway</html>',
          '{}',
          '{"tag_name":"2.3.9","assets":{}}',
        ]) {
          final source = GitHubReleaseMetadata(load: (_) async => response);
          await expectLater(source.latest(), throwsFormatException);
        }
      },
    );

    test(
      'draft and prerelease metadata do not become production updates',
      () async {
        for (final flag in ['draft', 'prerelease']) {
          final source = GitHubReleaseMetadata(
            load: (_) async =>
                jsonEncode({'tag_name': '2.3.10', 'assets': [], flag: true}),
          );
          expect(await source.latest(), isNull);
        }
      },
    );

    test('production prefixed tags display plainly and compare correctly', () {
      expect(getUpdateDisplayVersion('monogatari-v2.3.9'), '2.3.9');
      expect(getUpdateDisplayVersion('v2.3.9'), '2.3.9');
      expect(needUpdate('2.3.9', 'monogatari-v2.3.9'), isFalse);
      expect(needUpdate('2.3.8', 'monogatari-v2.3.9'), isTrue);
    });
  });

  group('matching actual release packages', () {
    final androidAssets = [
      _asset('Monogatari-Android-arm64.apk'),
      _asset('Monogatari-Android-armv7.apk'),
      _asset('Monogatari-Android-x64.apk'),
      _asset('Monogatari-Android.aab'),
    ];

    for (final (abi, expected) in [
      (Abi.androidArm64, 'Monogatari-Android-arm64.apk'),
      (Abi.androidArm, 'Monogatari-Android-armv7.apk'),
      (Abi.androidX64, 'Monogatari-Android-x64.apk'),
    ]) {
      test(
        'Android $abi selects its ABI package rather than the first APK',
        () {
          final asset = getUpdateAssetForType(
            androidAssets,
            InstallationType.androidApk,
            abi: abi,
          );
          expect(asset?['name'], expected);
          expect(
            getAvailableUpdateInstallationTypes(
              androidAssets,
              operatingSystem: 'android',
              abi: abi,
            ),
            [InstallationType.androidApk],
          );
        },
      );
    }

    test('a missing APK ABI never selects an incompatible APK or AAB', () {
      expect(
        getUpdateAssetForType(
          androidAssets,
          InstallationType.androidApk,
          abi: Abi.androidIA32,
        ),
        isNull,
      );
      expect(
        getAvailableUpdateInstallationTypes(
          androidAssets,
          operatingSystem: 'android',
          abi: Abi.androidIA32,
        ),
        isEmpty,
      );
    });

    test(
      'legacy Android names keep ARM64 compatibility without assuming x64',
      () {
        final asset = _asset('Kazumi_android_2.3.8.apk');
        expect(
          getUpdateAssetForType(
            [asset],
            InstallationType.androidApk,
            abi: Abi.androidArm64,
          )?['name'],
          asset['name'],
        );
        expect(
          getUpdateAssetForType(
            [asset],
            InstallationType.androidApk,
            abi: Abi.androidX64,
          ),
          isNull,
        );
      },
    );

    test('explicit universal APKs can update any supported Android ABI', () {
      final asset = _asset('Monogatari-Android-universal.apk');
      expect(
        getUpdateAssetForType(
          [asset],
          InstallationType.androidApk,
          abi: Abi.androidX64,
        )?['name'],
        asset['name'],
      );
    });

    test('legacy split APK names retain ABI matching', () {
      final assets = [
        _asset('Kazumi_android_arm64-v8a_2.3.8.apk'),
        _asset('Kazumi_android_x86_64_2.3.8.apk'),
        _asset('Kazumi_android_armeabi-v7a_2.3.8.apk'),
      ];
      expect(
        getUpdateAssetForType(
          assets,
          InstallationType.androidApk,
          abi: Abi.androidX64,
        )?['name'],
        'Kazumi_android_x86_64_2.3.8.apk',
      );
      expect(
        getUpdateAssetForType(
          assets,
          InstallationType.androidApk,
          abi: Abi.androidArm,
        )?['name'],
        'Kazumi_android_armeabi-v7a_2.3.8.apk',
      );
    });

    test('a Windows ZIP-only release exposes portable installation only', () {
      final assets = [_asset('Monogatari-Windows-x64.zip'), ...androidAssets];
      final available = getAvailableUpdateInstallationTypes(
        assets,
        operatingSystem: 'windows',
      );
      expect(available, [InstallationType.windowsPortable]);
      expect(
        getUpdateAssetForType(assets, InstallationType.windowsMsix),
        isNull,
      );
      expect(
        getUpdateAssetForType(assets, available.first)?['name'],
        'Monogatari-Windows-x64.zip',
      );
    });

    test('legacy Windows package names remain compatible', () {
      expect(
        getUpdateAssetForType([
          _asset('Kazumi_windows_2.3.8.zip'),
        ], InstallationType.windowsPortable)?['name'],
        'Kazumi_windows_2.3.8.zip',
      );
    });

    test(
      'iOS chooses the actual IPA from this release, not another platform',
      () {
        final ipa = _asset('Monogatari-iOS-unsigned.ipa');
        final available = getAvailableUpdateInstallationTypes([
          ...androidAssets,
          ipa,
        ], operatingSystem: 'ios');
        expect(available, [InstallationType.ios]);
        final asset = getUpdateAssetForType([
          ...androidAssets,
          ipa,
        ], InstallationType.ios);
        expect(
          getUpdateDownloadUrlFromAsset(asset),
          ipa['browser_download_url'],
        );
        expect(
          getAvailableUpdateInstallationTypes(
            androidAssets,
            operatingSystem: 'ios',
          ),
          isEmpty,
        );
      },
    );

    test(
      'mirror download URLs are ignored and cannot provide update packages',
      () {
        final asset = _asset('Monogatari-Windows-x64.zip')
          ..['mirror_download_url'] = 'https://bgm.monogatari.top/package.zip';
        expect(
          getUpdateDownloadUrlFromAsset(asset),
          asset['browser_download_url'],
        );
        asset.remove('browser_download_url');
        expect(getUpdateDownloadUrlFromAsset(asset), isEmpty);
        expect(
          getAvailableUpdateInstallationTypes([
            asset,
          ], operatingSystem: 'windows'),
          isEmpty,
        );
      },
    );

    test('non-GitHub and insecure package links cannot expose installers', () {
      for (final url in [
        'https://example.com/package.zip',
        'http://github.com/package.zip',
        'https://github.com.evil.example/package.zip',
      ]) {
        final asset = _asset('Monogatari-Windows-x64.zip')
          ..['browser_download_url'] = url;
        expect(getUpdateDownloadUrlFromAsset(asset), isEmpty);
        expect(
          getAvailableUpdateInstallationTypes([
            asset,
          ], operatingSystem: 'windows'),
          isEmpty,
        );
      }
    });

    test('missing digest is optional and a published SHA256 is retained', () {
      final asset = _asset('Monogatari-Windows-x64.zip');
      expect(getUpdateFileHashFromAsset(asset), isEmpty);
      final sha = List.filled(64, 'a').join();
      asset['digest'] = 'sha256:$sha';
      expect(getUpdateFileHashFromAsset(asset), sha);
    });
  });
}

Map<String, dynamic> _asset(String name) => {
  'name': name,
  'browser_download_url':
      'https://github.com/Teikaraku/monogatari-anime/releases/download/monogatari-v2.3.9/$name',
};
