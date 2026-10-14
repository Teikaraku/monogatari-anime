import 'dart:io';

/// Provider-controlled URLs never authorize cleartext or local-network access.
bool isPublicVideoUri(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.port != 443) {
    return false;
  }
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (!host.contains('.') && !host.contains(':')) return false;
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.lan') ||
      host.endsWith('.internal')) {
    return false;
  }
  final address = InternetAddress.tryParse(host);
  return address == null || isPublicVideoAddress(address);
}

bool isPublicVideoAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (bytes.length == 16) {
    if (bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255) {
      return isPublicVideoAddress(
        InternetAddress.fromRawAddress(bytes.sublist(12)),
      );
    }
    // Globally routable IPv6 unicast only; reject loopback, ULA, link-local,
    // multicast and IPv4 translation encodings that could hide private hosts.
    return (bytes[0] & 0xe0) == 0x20 &&
        !(bytes[0] == 0x20 && bytes[1] == 1 && bytes[2] < 2) &&
        !(bytes[0] == 0x20 && bytes[1] == 2) &&
        !(bytes[0] == 0x20 &&
            bytes[1] == 1 &&
            bytes[2] == 0x0d &&
            bytes[3] == 0xb8);
  }
  return bytes[0] != 0 &&
      bytes[0] != 10 &&
      bytes[0] != 127 &&
      bytes[0] < 224 &&
      !(bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) &&
      !(bytes[0] == 169 && bytes[1] == 254) &&
      !(bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) &&
      !(bytes[0] == 192 && bytes[1] == 168) &&
      !(bytes[0] == 192 && bytes[1] == 0 && bytes[2] == 0) &&
      !(bytes[0] == 192 && bytes[1] == 0 && bytes[2] == 2) &&
      !(bytes[0] == 198 && bytes[1] == 51 && bytes[2] == 100) &&
      !(bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113) &&
      !(bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19));
}

Future<void> validatePublicVideoUri(
  Uri uri, {
  Future<List<InternetAddress>> Function(String)? lookup,
}) async {
  if (!isPublicVideoUri(uri)) throw const FormatException('片源地址不符合安全要求');
  final addresses = await (lookup ?? InternetAddress.lookup)(
    uri.host,
  ).timeout(const Duration(seconds: 5));
  if (addresses.isEmpty ||
      addresses.any((address) => !isPublicVideoAddress(address))) {
    throw const FormatException('片源域名指向本地或非公开网络，已拒绝访问');
  }
}
