import 'dart:convert';
import 'dart:io';

/// MIME types on resource CDNs are often generic. Inspect a bounded prefix
/// so a successful HTTP error page cannot become a completed offline video.
Future<void> validateDownloadedMedia(
  File file, {
  bool requireContainerHeader = false,
}) async {
  final handle = await file.open();
  late List<int> prefix;
  try {
    prefix = await handle.read(512);
  } finally {
    await handle.close();
  }
  if (prefix.isEmpty) throw const FormatException('视频源返回了空内容');
  final text = utf8
      .decode(prefix, allowMalformed: true)
      .replaceFirst(RegExp(r'^\uFEFF'), '')
      .trimLeft()
      .toLowerCase();
  if (text.startsWith('<!doctype') ||
      text.startsWith('<html') ||
      text.startsWith('<head') ||
      text.startsWith('<body') ||
      text.startsWith('<?xml') ||
      _isJsonPayload(text) ||
      text.startsWith('access denied') ||
      text.startsWith('forbidden') ||
      text.startsWith('unauthorized')) {
    throw const FormatException('视频源返回了网页或错误信息');
  }
  // Segments may be encrypted or have an obfuscated prefix. Only complete
  // direct files must identify a supported media container here.
  if (requireContainerHeader && !_isMediaContainer(prefix)) {
    throw const FormatException('视频源返回了无效的视频文件');
  }
}

bool _isJsonPayload(String text) {
  if (!text.startsWith('{') && !text.startsWith('[')) return false;
  try {
    final decoded = jsonDecode(text);
    return decoded is Map || decoded is List;
  } on FormatException {
    return false;
  }
}

bool _isMediaContainer(List<int> prefix) {
  bool asciiAt(int offset, String value) {
    if (prefix.length < offset + value.length) return false;
    for (var i = 0; i < value.length; i++) {
      if (prefix[offset + i] != value.codeUnitAt(i)) return false;
    }
    return true;
  }

  if (prefix.length >= 8 &&
      const [
        'ftyp',
        'styp',
        'moov',
        'mdat',
        'wide',
        'free',
      ].any((box) => asciiAt(4, box))) {
    return true;
  }
  if (prefix.length >= 4 &&
      prefix[0] == 0x1a &&
      prefix[1] == 0x45 &&
      prefix[2] == 0xdf &&
      prefix[3] == 0xa3) {
    return true;
  }
  if (prefix.length >= 188 &&
      prefix[0] == 0x47 &&
      (prefix.length < 376 || prefix[188] == 0x47)) {
    return true;
  }
  return asciiAt(0, 'FLV') ||
      asciiAt(0, 'OggS') ||
      (asciiAt(0, 'RIFF') && asciiAt(8, 'AVI '));
}
