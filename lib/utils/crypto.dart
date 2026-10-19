import 'dart:io';

import 'package:crypto/crypto.dart';

Future<String> calculateFileHash(File file) async {
  final bytes = await file.readAsBytes();
  final digest = sha256.convert(bytes);
  return digest.toString();
}
