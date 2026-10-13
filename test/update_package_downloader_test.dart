import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/update/update_package_downloader.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory temporary;
  late Dio dio;
  late _PackageAdapter adapter;
  late UpdatePackageDownloader downloader;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'monogatari_update_test_',
    );
    adapter = _PackageAdapter((_) => _response(_zipBytes()));
    dio = Dio()..httpClientAdapter = adapter;
    downloader = UpdatePackageDownloader(
      dio: dio,
      temporaryDirectory: () async => temporary.path,
    );
  });
  tearDown(() async {
    dio.close(force: true);
    expect(path.isWithin(Directory.systemTemp.path, temporary.path), isTrue);
    expect(
      path.basename(temporary.path),
      startsWith('monogatari_update_test_'),
    );
    await temporary.delete(recursive: true);
  });

  test(
    'valid GitHub package is hashed then atomically promoted from .part',
    () async {
      final bytes = _zipBytes();
      var sawPartial = false;
      final result = await downloader.download(
        urls: [_url('app.apk')],
        fileName: 'Monogatari_android.apk',
        sha256: crypto.sha256.convert(bytes).toString(),
        onProgress: (received, _) {
          if (received > 0) {
            sawPartial |= temporary
                .listSync(recursive: true)
                .whereType<File>()
                .any((file) => file.path.endsWith('.part'));
          }
        },
      );
      expect(sawPartial, isTrue);
      expect(result.endsWith('.apk'), isTrue);
      expect(await File(result).readAsBytes(), bytes);
      expect(
        temporary
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.part')),
        isEmpty,
      );
      expect(
        adapter.requested.single.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('authorization')),
      );
    },
  );

  test('a mismatched declared SHA256 never yields an installer path', () async {
    await expectLater(
      downloader.download(
        urls: [_url('app.msix')],
        fileName: 'Monogatari.msix',
        sha256: '0' * 64,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'reason',
          contains('SHA256'),
        ),
      ),
    );
    expect(temporary.listSync(), isEmpty);
  });

  test(
    'empty, HTML and truncated ZIP bodies are refused even with HTTP 200',
    () async {
      for (final bytes in [
        <int>[],
        '<!doctype html><html>rate limited</html>'.codeUnits,
        _zipBytes().sublist(0, _zipBytes().length - 5),
      ]) {
        adapter.respond = (_) => _response(bytes);
        await expectLater(
          downloader.download(urls: [_url('app.apk')], fileName: 'app.apk'),
          throwsA(isA<FormatException>()),
        );
        expect(temporary.listSync(), isEmpty);
      }
    },
  );

  test(
    'invalid content is refused even if its advertised hash matches',
    () async {
      final html = '<html>temporarily unavailable</html>'.codeUnits;
      adapter.respond = (_) => _response(html);
      await expectLater(
        downloader.download(
          urls: [_url('app.zip')],
          fileName: 'app.zip',
          sha256: crypto.sha256.convert(html).toString(),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(temporary.listSync(), isEmpty);
    },
  );

  test(
    'cancellation after the last bytes removes .part and never succeeds',
    () async {
      final cancellation = CancelToken();
      await expectLater(
        downloader.download(
          urls: [_url('app.apk')],
          fileName: 'app.apk',
          cancelToken: cancellation,
          onProgress: (received, _) {
            if (received > 0) cancellation.cancel('user cancelled');
          },
        ),
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(temporary.listSync(), isEmpty);
    },
  );

  test('a fallback candidate starts fresh after a network failure', () async {
    final bytes = _zipBytes();
    adapter.respond = (options) => options.uri.path.endsWith('first.apk')
        ? ResponseBody.fromString('unavailable', 503)
        : _response(bytes);
    final result = await downloader.download(
      urls: [_url('first.apk'), _url('second.apk')],
      fileName: 'app.apk',
      sha256: crypto.sha256.convert(bytes).toString(),
    );
    expect(adapter.requested.length, 2);
    expect(await File(result).readAsBytes(), bytes);
  });

  test(
    'a 200 error page cannot contribute bytes to the next candidate',
    () async {
      final bytes = _zipBytes();
      adapter.respond = (options) => options.uri.path.endsWith('first.apk')
          ? _response('<html>download denied</html>'.codeUnits)
          : _response(bytes);
      final result = await downloader.download(
        urls: [_url('first.apk'), _url('second.apk')],
        fileName: 'app.apk',
      );
      expect(adapter.requested.length, 2);
      expect(await File(result).readAsBytes(), bytes);
    },
  );

  test('non GitHub URL and path-like names fail before networking', () async {
    for (final invocation in [
      () => downloader.download(
        urls: [Uri.parse('https://example.com/app.apk')],
        fileName: 'app.apk',
      ),
      () =>
          downloader.download(urls: [_url('app.apk')], fileName: '../app.apk'),
      () => downloader.download(
        urls: [_url('app.apk')],
        fileName: 'app.apk:other',
      ),
    ]) {
      await expectLater(invocation(), throwsA(isA<FormatException>()));
    }
    expect(adapter.requested, isEmpty);
    expect(temporary.listSync(), isEmpty);
  });

  test(
    'GitHub asset redirects are accepted and foreign redirects are refused',
    () async {
      adapter.respond = (_) => _response(_zipBytes())
        ..redirects = [
          RedirectRecord(
            302,
            'GET',
            Uri.parse(
              'https://release-assets.githubusercontent.com/asset/app.apk',
            ),
          ),
        ];
      final result = await downloader.download(
        urls: [_url('app.apk')],
        fileName: 'app.apk',
      );
      expect(await File(result).exists(), isTrue);
      adapter.respond = (_) => _response(_zipBytes())
        ..redirects = [
          RedirectRecord(302, 'GET', Uri.parse('https://example.com/app.apk')),
        ];
      await expectLater(
        downloader.download(urls: [_url('app.apk')], fileName: 'app.apk'),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'DMG packages require their UDIF footer rather than a HTTP success',
    () async {
      final good = Uint8List(1024);
      good.setAll(512, 'koly'.codeUnits);
      adapter.respond = (_) => _response(good);
      final result = await downloader.download(
        urls: [_url('app.dmg')],
        fileName: 'Monogatari_macos.dmg',
      );
      expect(await File(result).length(), 1024);
      adapter.respond = (_) => _response(Uint8List(1024));
      await expectLater(
        downloader.download(urls: [_url('app.dmg')], fileName: 'bad.dmg'),
        throwsA(isA<FormatException>()),
      );
    },
  );
}

Uri _url(String name) =>
    Uri.parse('https://github.com/owner/Monogatari/releases/download/v2/$name');

ResponseBody _response(List<int> bytes) => ResponseBody.fromBytes(
  bytes,
  200,
  headers: {
    'content-type': ['application/octet-stream'],
    'content-length': ['${bytes.length}'],
  },
);

class _PackageAdapter implements HttpClientAdapter {
  _PackageAdapter(this.respond);
  ResponseBody Function(RequestOptions) respond;
  final requested = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

/// A real, single-entry stored ZIP, with matching local/central offsets, CRC,
/// entry sizes and end-of-central-directory metadata.
List<int> _zipBytes() {
  final name = 'AndroidManifest.xml'.codeUnits;
  final payload = '<manifest/>'.codeUnits;
  final local = Uint8List(30);
  final central = Uint8List(46);
  final end = Uint8List(22);
  final l = ByteData.sublistView(local);
  final c = ByteData.sublistView(central);
  final e = ByteData.sublistView(end);
  l.setUint32(0, 0x04034b50, Endian.little);
  l.setUint16(4, 20, Endian.little);
  l.setUint32(14, _crc32(payload), Endian.little);
  l.setUint32(18, payload.length, Endian.little);
  l.setUint32(22, payload.length, Endian.little);
  l.setUint16(26, name.length, Endian.little);
  c.setUint32(0, 0x02014b50, Endian.little);
  c.setUint16(4, 20, Endian.little);
  c.setUint16(6, 20, Endian.little);
  c.setUint32(16, _crc32(payload), Endian.little);
  c.setUint32(20, payload.length, Endian.little);
  c.setUint32(24, payload.length, Endian.little);
  c.setUint16(28, name.length, Endian.little);
  e.setUint32(0, 0x06054b50, Endian.little);
  e.setUint16(8, 1, Endian.little);
  e.setUint16(10, 1, Endian.little);
  e.setUint32(12, central.length + name.length, Endian.little);
  e.setUint32(16, local.length + name.length + payload.length, Endian.little);
  return [...local, ...name, ...payload, ...central, ...name, ...end];
}

int _crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = crc & 1 != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}
