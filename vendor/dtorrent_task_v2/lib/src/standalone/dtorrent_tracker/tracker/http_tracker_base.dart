import 'dart:async';
import 'dart:io';

import 'dart:typed_data';

///
/// Because access announce or scrape url , the access workflow is the same , but different url
/// with diffrent query string. So this class implement the http access announce main processes,
/// such as connect , catch error , close client and so on.
///
/// The classes which [with] this mixin , need to implement ```generateQueryParameters``` method, ```url``` property
/// ```processResponseData``` method.
/// - ```generateQueryParameters``` return the query parameters map , this class will make them to be the query string
/// - ```url``` the announce or scrape url
/// - ```processResponseData``` deal with the response byte buffer , and return the useful informations from announce.
///
///
/// Invoke ```httpGet``` method to start access remote , see HttpTracker:
///
/// ```dart
///    @override
///    Future announce(String event) {
///      _currentEvent = event;
///      return httpGet();
///    }
///
/// ```
///
/// It record the event type and invoke httpGet directly to access remote. of course , it has implemented the abstract method and
/// property of this mixin.
///
///
mixin HttpTrackerBase {
  Duration get requestTimeout => const Duration(seconds: 12);
  int get maximumResponseBytes => 2 * 1024 * 1024;
  HttpClient? _httpClient;

  HttpClientRequest? _request;
  StreamSubscription? _sc;

  /// Return a map with query params.
  /// [options] is a map , it help to generate paramter
  ///
  /// *NOTE*
  ///
  /// The param map's key is the query pair'key , it allow the duplicated key:
  ///
  /// `http://some.com?key=value1&key=value2`
  ///
  /// so , the param map's value is not `String` type but `dynamic`, because it can be a `List`.
  /// If the value is `List` , the query string will be generated with duplicate key :
  /// ```dart
  ///   var map = <String,List>{};
  ///   var list = ['Sam','Bob'];
  ///   map['name'] = list;
  ///   return map;
  /// ```
  /// Then access url with the query string will be : `http://remoteurl?name=Sam&name=Bob`
  Map<String, dynamic>? generateQueryParameters(Map<String, dynamic> options);

  /// Return the remote Url
  Uri get url;

  bool _closed = false;

  bool get isClosed => _closed;

  /// Create an access URL.
  ///
  /// Subclasses must implement the 'url' property and
  /// the 'generateQueryParameters' method to correctly initiate the access
  String _createAccessURL(Map<String, dynamic> options) {
    var parameters = generateQueryParameters(options);
    if (parameters == null || parameters.isEmpty) {
      throw Exception('Query params can not be empty');
    }
    var queryStr = parameters.keys.fold<String>('', (previousValue, key) {
      var values = parameters[key];
      if (values is String) {
        previousValue += '&$key=$values';
        return previousValue;
      }
      if (values is List) {
        for (var value in values) {
          previousValue += '&$key=$value';
        }
        return previousValue;
      }
      return previousValue;
    });
    // if (_queryStr.isNotEmpty) _queryStr = _queryStr.substring(1); scrape
    // Preserve tracker passkeys and routing parameters from the torrent URL.
    return '${url.origin}${url.path}?${url.hasQuery ? url.query : ''}$queryStr';
  }

  ///
  /// close the http client
  Future<void> close() async {
    _closed = true;
    await _clear();
  }

  Future<void> _clear() async {
    _httpClient?.close(force: true);
    _httpClient = null;
    _request?.abort();
    _request = null;
    await _sc?.cancel();
    _sc = null;
  }

  Future<List<int>> _receiveResponseData(HttpClientResponse? response) async {
    var c = Completer<List<int>>();
    var d = <int>[];
    _sc = response?.listen((event) {
      if (c.isCompleted) return;
      if (d.length + event.length > maximumResponseBytes) {
        c.completeError(const FormatException('Tracker response is too large'));
        return;
      }
      d.addAll(event);
    }, onDone: () {
      if (!c.isCompleted) c.complete(d);
    }, onError: (e) {
      if (!c.isCompleted) c.completeError(e);
    });
    return c.future;
  }

  ///
  /// HTTP GET request. Returns a Future. If there is an issue with the access,
  /// such as a non-200 response code, timeout, problems with data reception,
  /// URL parsing errors, etc., they will all be caught by the Future's
  /// catchError.
  ///
  Future<T?> httpGet<T>(Map<String, dynamic> options) async {
    if (isClosed) {
      return null;
    }
    try {
      return await _httpGet<T>(options).timeout(requestTimeout);
    } finally {
      await _clear();
    }
  }

  Future<T?> _httpGet<T>(Map<String, dynamic> options) async {
    var uri = Uri.parse(_createAccessURL(options));
    _httpClient?.close();
    _httpClient = HttpClient()..connectionTimeout = requestTimeout;
    _request?.abort();
    _request = await _httpClient?.getUrl(uri);
    var response = await _request?.close();
    if (response?.statusCode != HttpStatus.ok) {
      throw HttpException('Tracker returned HTTP ${response?.statusCode}');
    }
    var datas = await _receiveResponseData(response);
    return processResponseData(Uint8List.fromList(datas)) as T?;
  }

  /// Process the remote response byte buffer and return the useful informations they need.
  Object? processResponseData(Uint8List data);
}
