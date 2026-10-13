import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Downloads public GitHub release assets without authentication. An
/// installer receives a path only after the entire package passes validation.
class UpdatePackageDownloader {
  UpdatePackageDownloader({
    Dio? dio,
    Future<String> Function()? temporaryDirectory,
  }) : _dio = dio,
       _temporaryDirectory = temporaryDirectory ?? _defaultTemporaryDirectory;

  final Dio? _dio;
  final Future<String> Function() _temporaryDirectory;

  static Future<String> _defaultTemporaryDirectory() async =>
      (await getTemporaryDirectory()).path;

  static const _githubHosts = {
    'github.com',
    'api.github.com',
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
    'github-releases.githubusercontent.com',
  };

  Future<String> download({
    required List<Uri> urls,
    required String fileName,
    String? sha256,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    _checkCancellation(cancelToken);
    if (urls.isEmpty) throw const FormatException('没有可用的更新下载地址');
    if (path.basename(fileName) != fileName ||
        fileName.isEmpty ||
        fileName == '.' ||
        fileName == '..' ||
        RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(fileName)) {
      throw const FormatException('更新安装包文件名无效');
    }
    for (final url in urls) {
      if (url.scheme != 'https' ||
          !_githubHosts.contains(url.host.toLowerCase()) ||
          url.userInfo.isNotEmpty) {
        throw const FormatException('更新安装包必须来自 GitHub');
      }
    }
    final expectedHash = (sha256 ?? '').trim().toLowerCase().replaceFirst(
      RegExp(r'^sha256:'),
      '',
    );
    if (expectedHash.isNotEmpty &&
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedHash)) {
      throw const FormatException('更新安装包 SHA256 信息无效');
    }
    final root = Directory(await _temporaryDirectory());
    await root.create(recursive: true);
    _checkCancellation(cancelToken);
    final working = await root.createTemp('monogatari_update_');
    final complete = File(path.join(working.path, fileName));
    final partial = File('${complete.path}.part');
    try {
      Object? lastError;
      for (final url in urls.toSet()) {
        _checkCancellation(cancelToken);
        if (await partial.exists()) await partial.delete();
        try {
          onProgress?.call(0, 0);
          await _downloadCandidate(url, partial, cancelToken, onProgress);
          _checkCancellation(cancelToken);
          if (expectedHash.isNotEmpty) {
            final digest = await crypto.sha256
                .bind(
                  partial.openRead().map((chunk) {
                    _checkCancellation(cancelToken);
                    return chunk;
                  }),
                )
                .first;
            if (digest.toString() != expectedHash) {
              throw const FormatException('文件完整性验证失败 (SHA256 不匹配)');
            }
          }
          await _validatePackage(partial, fileName);
          _checkCancellation(cancelToken);
          await partial.rename(complete.path);
          _checkCancellation(cancelToken);
          return complete.path;
        } on FileSystemException {
          rethrow;
        } catch (error) {
          _checkCancellation(cancelToken);
          if (error is DioException && error.type == DioExceptionType.cancel) {
            rethrow;
          }
          lastError = error;
        }
      }
      throw lastError ?? const FormatException('更新安装包下载失败');
    } catch (_) {
      // This directory is created exclusively for this one download; failed
      // candidates and cancellations must not leave a usable installer path.
      if (path.isWithin(root.absolute.path, working.absolute.path)) {
        try {
          await working.delete(recursive: true);
        } on FileSystemException {
          // Cleanup failure never turns an invalid package into a success.
        }
      }
      rethrow;
    }
  }

  void _checkCancellation(CancelToken? token) {
    if (token?.isCancelled == true) throw token!.cancelError!;
  }

  Future<void> _downloadCandidate(
    Uri url,
    File partial,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  ) async {
    final response = await (_dio ?? DioFactory.downloadDio).get<ResponseBody>(
      url.toString(),
      options: Options(
        headers: {'accept': 'application/octet-stream'},
        responseType: ResponseType.stream,
      ),
      cancelToken: cancelToken,
    );
    final body = response.data;
    if (body == null) throw const FormatException('更新服务器返回了空响应');
    final chunks = StreamIterator(body.stream);
    RandomAccessFile? output;
    try {
      if (!_githubHosts.contains(response.realUri.host.toLowerCase()) ||
          response.realUri.scheme != 'https') {
        throw const FormatException('更新安装包重定向到了非 GitHub 地址');
      }
      _checkCancellation(cancelToken);
      output = await partial.open(mode: FileMode.write);
      final total =
          int.tryParse(
            response.headers.value(Headers.contentLengthHeader) ?? '',
          ) ??
          -1;
      var received = 0;
      while (await chunks.moveNext()) {
        _checkCancellation(cancelToken);
        await output.writeFrom(chunks.current);
        received += chunks.current.length;
        onProgress?.call(received, total);
        _checkCancellation(cancelToken);
      }
      if (total >= 0 &&
          received < total &&
          response.headers.value('content-encoding') == null) {
        throw const FormatException('更新安装包下载不完整');
      }
      await output.flush();
    } finally {
      // Own and close the native file handle before reporting cancellation or
      // deleting .part on Windows. Dio.download can throw before its hidden
      // writer has closed, leaving a locked partial file behind.
      try {
        await output?.close();
      } finally {
        await chunks.cancel();
      }
    }
  }

  Future<void> _validatePackage(File file, String fileName) async {
    final size = await file.length();
    if (size == 0) throw const FormatException('更新服务器返回了空文件');
    final extension = path.extension(fileName).toLowerCase();
    if (const [
      '.apk',
      '.msix',
      '.msixbundle',
      '.zip',
      '.ipa',
    ].contains(extension)) {
      await _validateZip(file, size);
      return;
    }
    if (extension == '.dmg') {
      if (size <= 512) throw const FormatException('更新 DMG 安装包不完整');
      final handle = await file.open();
      try {
        await handle.setPosition(size - 512);
        if (!_matches(await handle.read(4), [0x6b, 0x6f, 0x6c, 0x79])) {
          throw const FormatException('更新服务器返回了无效的 DMG 安装包');
        }
      } finally {
        await handle.close();
      }
      return;
    }
    throw const FormatException('不支持验证该更新安装包类型');
  }

  Future<void> _validateZip(File file, int size) async {
    if (size < 53) throw const FormatException('更新 ZIP 安装包为空或不完整');
    final handle = await file.open();
    try {
      if (!_matches(await handle.read(4), [0x50, 0x4b, 0x03, 0x04])) {
        throw const FormatException('更新服务器返回了无效的安装包');
      }
      final tailSize = size < 65557 ? size : 65557;
      await handle.setPosition(size - tailSize);
      final tail = await handle.read(tailSize);
      int? end;
      for (var i = tail.length - 22; i >= 0; i--) {
        if (_matches(tail.sublist(i, i + 4), [0x50, 0x4b, 0x05, 0x06]) &&
            i + 22 + _u16(tail, i + 20) == tail.length) {
          end = i;
          break;
        }
      }
      if (end == null) throw const FormatException('更新安装包下载不完整');
      final totalEntries = _u16(tail, end + 10);
      final centralSize = _u32(tail, end + 12);
      final centralOffset = _u32(tail, end + 16);
      final endOffset = size - tailSize + end;
      if (_u16(tail, end + 4) != 0 ||
          _u16(tail, end + 6) != 0 ||
          _u16(tail, end + 8) != totalEntries ||
          totalEntries == 0 ||
          totalEntries == 0xffff ||
          centralOffset + centralSize > endOffset) {
        throw const FormatException('更新安装包目录无效');
      }
      var position = centralOffset;
      var hasFileData = false;
      for (var i = 0; i < totalEntries; i++) {
        if (position + 46 > centralOffset + centralSize) {
          throw const FormatException('更新安装包目录不完整');
        }
        await handle.setPosition(position);
        final entry = await handle.read(46);
        if (entry.length != 46 ||
            !_matches(entry.sublist(0, 4), [0x50, 0x4b, 0x01, 0x02])) {
          throw const FormatException('更新安装包目录无效');
        }
        final compressedSize = _u32(entry, 20);
        final uncompressedSize = _u32(entry, 24);
        final localOffset = _u32(entry, 42);
        if (localOffset + 30 > centralOffset) {
          throw const FormatException('更新安装包数据无效');
        }
        await handle.setPosition(localOffset);
        final local = await handle.read(30);
        if (local.length != 30 ||
            !_matches(local.sublist(0, 4), [0x50, 0x4b, 0x03, 0x04]) ||
            localOffset +
                    30 +
                    _u16(local, 26) +
                    _u16(local, 28) +
                    compressedSize >
                centralOffset) {
          throw const FormatException('更新安装包数据不完整');
        }
        hasFileData |= uncompressedSize > 0 && compressedSize > 0;
        position += 46 + _u16(entry, 28) + _u16(entry, 30) + _u16(entry, 32);
      }
      if (position != centralOffset + centralSize || !hasFileData) {
        throw const FormatException('更新安装包为空或目录无效');
      }
    } finally {
      await handle.close();
    }
  }

  bool _matches(List<int> data, List<int> expected) {
    if (data.length < expected.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (data[i] != expected[i]) return false;
    }
    return true;
  }

  int _u16(List<int> data, int offset) => ByteData.sublistView(
    Uint8List.fromList(data),
    offset,
    offset + 2,
  ).getUint16(0, Endian.little);
  int _u32(List<int> data, int offset) => ByteData.sublistView(
    Uint8List.fromList(data),
    offset,
    offset + 4,
  ).getUint32(0, Endian.little);
}
