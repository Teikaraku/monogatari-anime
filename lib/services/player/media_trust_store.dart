import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Native FFmpeg builds do not consistently inherit the OS certificate store.
/// Export the existing Mozilla bundle; retain certificate verification.
class MediaTrustStore {
  MediaTrustStore._();
  static Future<String>? _path;

  static Future<String> caFile() =>
      _path ??= _export().catchError((Object error) {
        _path = null;
        throw error;
      });

  static Future<String> _export() async {
    final data = await rootBundle.load('licenses/ech_http/cacert.pem');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final file = File(
      p.join(directory.path, 'media-ca-${sha256.convert(bytes)}.pem'),
    );
    if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
