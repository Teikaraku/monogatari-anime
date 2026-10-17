import 'package:kazumi/request/config/api_endpoints.dart';

/// Routes Bangumi images through the Monogatari relay, which caches
/// lain.bgm.tv under /img/ and redirects the image API there.
abstract final class BangumiImageUrlRewriter {
  static const _apiImageKinds = {'subjects', 'characters', 'persons'};

  static final Uri _relay = Uri.parse(ApiEndpoints.bangumiMirrorDomain);

  static Uri rewrite(Uri uri) {
    if (!isBangumiImage(uri)) return uri;
    uri = originalImage(uri);

    final path = uri.host == 'lain.bgm.tv' ? '/img${uri.path}' : uri.path;
    return _relay.replace(path: path, query: uri.hasQuery ? uri.query : null);
  }

  /// The new `/r/<size>/` image processor can stall even when the original
  /// static image is fast. Cache the original and let the UI resize it.
  static Uri originalImage(Uri uri) {
    if (uri.host != 'lain.bgm.tv' || !_isHttp(uri)) return uri;
    final path = uri.path.replaceFirst(
      RegExp(r'^/r/\d+(?:x\d+)?(?=/pic/(?:cover|crt)/)'),
      '',
    );
    return uri.replace(scheme: 'https', path: path);
  }

  static bool _isHttp(Uri uri) => uri.scheme == 'http' || uri.scheme == 'https';

  static bool isBangumiImage(Uri uri) =>
      _isHttp(uri) && (uri.host == 'lain.bgm.tv' || _isApiImage(uri));

  static bool _isApiImage(Uri uri) {
    if (uri.host != 'api.bgm.tv') return false;

    final segments = uri.pathSegments;
    if (segments.length != 4 || segments[0] != 'v0' || segments[3] != 'image') {
      return false;
    }
    final id = int.tryParse(segments[2]);
    return _apiImageKinds.contains(segments[1]) && id != null && id > 0;
  }
}
