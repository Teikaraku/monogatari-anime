/// Pure Dart constants shared by the UI and torrent worker isolate.
const publicCatalogOrigin = String.fromEnvironment(
  'PUBLIC_CATALOG_ORIGIN',
  defaultValue: '',
);

Uri? publicCatalogUri([String origin = publicCatalogOrigin]) {
  final uri = Uri.tryParse(origin);
  if (uri == null ||
      !const {'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri;
}

String publicCatalogEndpoint(String path) =>
    publicCatalogUri()?.resolve(path).toString() ?? '';
