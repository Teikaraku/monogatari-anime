import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';
import 'package:dio/io.dart';
import 'dart:io';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/api_video/public_video_proxy.dart';
import 'package:kazumi/services/api_video/api_video_url_policy.dart';

class DownloadHttpClient {
  DownloadHttpClient._();

  static final DownloadHttpClient instance = DownloadHttpClient._();
  Future<Dio>? _publicDio;

  Future<Dio> _client(String url, bool publicNetworkOnly) async {
    if (!publicNetworkOnly) return DioFactory.downloadDio;
    if (!isPublicVideoUri(Uri.parse(url))) {
      throw const FormatException('片源地址不符合安全要求');
    }
    return _publicDio ??= _createPublicClient().catchError((Object error) {
      _publicDio = null;
      throw error;
    });
  }

  Future<Dio> _createPublicClient() async {
    final route = PublicVideoProxy(
      proxyForUri: (uri) => NetworkConfig.fromSettings().proxyForUri(uri),
    );
    await route.start();
    final dio = DioFactory.createForConfig(
      const NetworkConfig(
        connectTimeout: Duration(seconds: 15),
        receiveTimeout: Duration(seconds: 30),
        enableLog: false,
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.maxConnectionsPerHost = 4;
        client.findProxy = (_) => 'DIRECT';
        client.connectionFactory = (uri, _, _) =>
            route.secureConnectionTask(uri);
        return client;
      },
    );
    return dio;
  }

  Future<Response<ResponseBody>> getStream(
    String url, {
    Map<String, dynamic> headers = const {},
    Duration? receiveTimeout,
    CancelToken? cancelToken,
    bool publicNetworkOnly = false,
  }) async {
    try {
      return await (await _client(url, publicNetworkOnly)).get<ResponseBody>(
        url,
        options: Options(
          headers: headers,
          responseType: ResponseType.stream,
          receiveTimeout: receiveTimeout,
        ),
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  Future<String> getPlain(
    String url, {
    Map<String, dynamic> headers = const {},
    Duration? receiveTimeout,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
    bool publicNetworkOnly = false,
  }) async {
    try {
      final response = await (await _client(url, publicNetworkOnly))
          .get<String>(
            url,
            options: Options(
              headers: headers,
              responseType: ResponseType.plain,
              receiveTimeout: receiveTimeout,
            ),
            cancelToken: cancelToken,
            onReceiveProgress: onReceiveProgress,
          );
      return response.data ?? '';
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  Future<void> download(
    String url,
    String savePath, {
    Map<String, dynamic> headers = const {},
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
    bool publicNetworkOnly = false,
  }) async {
    try {
      await (await _client(url, publicNetworkOnly)).download(
        url,
        savePath,
        options: Options(headers: headers),
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
      );
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }
}
