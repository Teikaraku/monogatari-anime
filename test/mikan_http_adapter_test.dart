import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kazumi/services/network/mikan_http_adapter.dart';

void main() {
  late _PlainAdapter plain;
  late _EncryptedClient encrypted;
  late MikanHttpAdapter adapter;

  setUp(() {
    plain = _PlainAdapter();
    encrypted = _EncryptedClient();
    adapter = MikanHttpAdapter(
      relayOrigin: 'https://relay.example.test',
      enablePublicRelay: false,
      fallback: plain,
      proxyForUri: (_) => null,
      createEchClient: () => encrypted,
      discoveryTimeout: const Duration(milliseconds: 100),
    );
  });
  tearDown(() => adapter.close(force: true));

  test(
    'public RSS can use a healthy relay and abort a stalled ECH route',
    () async {
      encrypted.waitForAbort = true;
      plain.payload = '<rss><channel></channel></rss>';
      final combined = MikanHttpAdapter(
        relayOrigin: 'https://relay.example.test',
        fallback: plain,
        proxyForUri: (_) => null,
        createEchClient: () => encrypted,
      );
      addTearDown(() => combined.close(force: true));
      final response = await combined.fetch(
        _options('/RSS/Bangumi?bangumiId=4062&subgroupid=583'),
        null,
        null,
      );
      await response.stream.drain<void>();
      await Future<void>.delayed(Duration.zero);
      expect(plain.requests.single.uri.host, 'relay.example.test');
      expect(plain.requests.single.uri.path, '/public/mikan/RSS/Bangumi');
      expect(encrypted.aborted, isTrue);
    },
  );

  test('force-close cancels a pending public relay race immediately', () async {
    encrypted.waitForAbort = true;
    plain.waitForAbort = true;
    final combined = MikanHttpAdapter(
      relayOrigin: 'https://relay.example.test',
      fallback: plain,
      proxyForUri: (_) => null,
      createEchClient: () => encrypted,
    );
    final pending = combined.fetch(
      _options('/RSS/Bangumi?bangumiId=4062'),
      null,
      null,
    );
    await encrypted.started.future;
    combined.close(force: true);
    await expectLater(
      pending.timeout(const Duration(seconds: 1)),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
  });

  test('relay is never used for a token feed or configured proxy', () async {
    final combined = MikanHttpAdapter(
      relayOrigin: 'https://relay.example.test',
      fallback: plain,
      proxyForUri: (_) => null,
      createEchClient: () => encrypted,
    );
    addTearDown(() => combined.close(force: true));
    await (await combined.fetch(
      _options('/RSS/MyBangumi?token=secret'),
      null,
      null,
    )).stream.drain<void>();
    expect(plain.requests, isEmpty);
    final proxied = MikanHttpAdapter(
      relayOrigin: 'https://relay.example.test',
      fallback: plain,
      proxyForUri: (_) => Uri.parse('http://proxy.test:8080'),
    );
    addTearDown(() => proxied.close(force: true));
    await (await proxied.fetch(
      _options('/RSS/Bangumi?bangumiId=4062'),
      null,
      null,
    )).stream.drain<void>();
    expect(plain.requests.single.uri.host, 'mikanani.me');
  });

  test('configured public API hosts use ECH while other hosts stay on their original transport', () async {
    final configured = MikanHttpAdapter(
      relayOrigin: 'https://relay.example.test',
      enablePublicRelay: false,
      fallback: plain,
      proxyForUri: (_) => null,
      hosts: const {'bfzyapi.com'},
      createEchClient: () => encrypted,
    );
    addTearDown(() => configured.close(force: true));
    final response = await configured.fetch(
      RequestOptions(path: 'https://bfzyapi.com/api.php'),
      null,
      null,
    );
    await response.stream.drain<void>();
    final untouched = await configured.fetch(
      RequestOptions(path: 'https://personal.test/rss?token=private'),
      null,
      null,
    );
    await untouched.stream.drain<void>();
    expect(encrypted.requests.single.url.host, 'bfzyapi.com');
    expect(plain.requests.single.uri.host, 'personal.test');
  });

  test('a stalled edge is bypassed without waiting for its timeout', () async {
    encrypted.waitForAbort = true;
    final backup = _EncryptedClient();
    final hedged = MikanHttpAdapter(
      relayOrigin: 'https://relay.example.test',
      enablePublicRelay: false,
      fallback: plain,
      proxyForUri: (_) => null,
      createEchClient: () => encrypted,
      createSecondaryEchClient: () => backup,
      hedgeDelay: const Duration(milliseconds: 5),
    );
    addTearDown(() => hedged.close(force: true));
    final response = await hedged
        .fetch(_options('/RSS/Classic'), null, null)
        .timeout(const Duration(seconds: 1));
    expect(response.statusCode, 200);
    await response.stream.drain<void>();
    await Future<void>.delayed(Duration.zero);
    expect(encrypted.aborted, isTrue);
    expect(backup.requests, hasLength(1));
    expect(plain.requests, isEmpty);
  });

  test('a refused encrypted edge cannot win over a working edge', () async {
    encrypted.status = 403;
    final backup = _EncryptedClient();
    final hedged = MikanHttpAdapter(
      relayOrigin: 'https://relay.example.test',
      enablePublicRelay: false,
      fallback: plain,
      proxyForUri: (_) => null,
      createEchClient: () => encrypted,
      createSecondaryEchClient: () => backup,
      hedgeDelay: const Duration(milliseconds: 5),
    );
    addTearDown(() => hedged.close(force: true));
    final response = await hedged.fetch(_options('/RSS/Classic'), null, null);
    expect(response.statusCode, 200);
    await response.stream.drain<void>();
    expect(plain.requests, isEmpty);
  });

  test(
    'fast headers with a stalled body cannot cancel the healthy backup',
    () async {
      encrypted.stallBody = true;
      final hedged = MikanHttpAdapter(
        relayOrigin: 'https://relay.example.test',
        enablePublicRelay: false,
        fallback: plain,
        proxyForUri: (_) => null,
        createEchClient: () => encrypted,
        createSecondaryEchClient: () => _EncryptedClient(),
        hedgeDelay: const Duration(milliseconds: 5),
      );
      addTearDown(() => hedged.close(force: true));
      final response = await hedged
          .fetch(_options('/RSS/Classic'), null, null)
          .timeout(const Duration(seconds: 1));
      expect(await response.stream.toList(), isNotEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(encrypted.aborted, isTrue);
      expect(plain.requests, isEmpty);
    },
  );

  test(
    'oversized encrypted documents are rejected before reaching the parser',
    () async {
      final bounded = MikanHttpAdapter(
        relayOrigin: 'https://relay.example.test',
        enablePublicRelay: false,
        fallback: plain,
        proxyForUri: (_) => null,
        createEchClient: () => encrypted,
        maxResponseBytes: 4,
      );
      addTearDown(() => bounded.close(force: true));
      final response = await bounded.fetch(
        _options('/RSS/Classic'),
        null,
        null,
      );
      await response.stream.drain<void>();
      expect(plain.requests, hasLength(1));
    },
  );

  test(
    'Mikan direct RSS and torrent metadata use the encrypted route',
    () async {
      for (final path in [
        '/RSS/MyBangumi?token=private-token',
        '/Download/20261013/${'a' * 40}.torrent',
      ]) {
        final response = await adapter.fetch(_options(path), null, null);
        expect(await response.stream.toList(), isNotEmpty);
        expect(response.statusCode, 200);
      }
      expect(encrypted.requests, hasLength(2));
      expect(plain.requests, isEmpty);
      expect(encrypted.requests.first.followRedirects, isFalse);
      expect(encrypted.requests.first.headers['accept'], 'test');
    },
  );

  test('explicit proxy is preserved and never bypassed through ECH', () async {
    final proxied = MikanHttpAdapter(
      relayOrigin: 'https://relay.example.test',
      enablePublicRelay: false,
      fallback: plain,
      proxyForUri: (_) => Uri.parse('http://127.0.0.1:7890'),
      createEchClient: () => encrypted,
    );
    addTearDown(() => proxied.close(force: true));
    final response = await proxied.fetch(_options('/RSS/Classic'), null, null);
    await response.stream.drain<void>();
    expect(plain.requests, hasLength(1));
    expect(encrypted.requests, isEmpty);
  });

  test(
    'ECH failure falls back to normal HTTPS without exposing request secrets',
    () async {
      encrypted.fail = true;
      final response = await adapter.fetch(
        _options('/RSS/MyBangumi?token=private-token'),
        null,
        null,
      );
      expect(response.statusCode, 200);
      await response.stream.drain<void>();
      expect(plain.requests, hasLength(1));
    },
  );

  test(
    'a stalled ECH discovery is cancelled before bounded HTTPS fallback',
    () async {
      encrypted.waitForAbort = true;
      final response = await adapter.fetch(
        _options('/RSS/Classic'),
        null,
        null,
      );
      await response.stream.drain<void>();
      expect(encrypted.aborted, isTrue);
      expect(plain.requests, hasLength(1));
    },
  );

  test('caller cancellation does not start a fallback request', () async {
    encrypted.waitForAbort = true;
    final cancellation = Completer<void>();
    final pending = adapter.fetch(
      _options('/RSS/MyBangumi?token=private-token'),
      null,
      cancellation.future,
    );
    await encrypted.started.future;
    cancellation.complete();
    await expectLater(
      pending,
      throwsA(
        isA<DioException>()
            .having((error) => error.type, 'type', DioExceptionType.cancel)
            .having(
              (error) => error.message,
              'message',
              isNot(contains('private-token')),
            ),
      ),
    );
    expect(plain.requests, isEmpty);
  });

  test(
    'unrelated hosts and non-GET requests keep ordinary HTTP behavior',
    () async {
      for (final options in [
        RequestOptions(path: 'https://example.test/file.torrent'),
        RequestOptions(path: 'http://mikanani.me/RSS/Classic'),
        RequestOptions(path: 'https://mikanani.me/RSS/Classic', method: 'POST'),
      ]) {
        final response = await adapter.fetch(options, null, null);
        await response.stream.drain<void>();
      }
      expect(plain.requests, hasLength(3));
      expect(encrypted.requests, isEmpty);
    },
  );

  test(
    'closing an active adapter cancels native work without fallback',
    () async {
      encrypted.waitForAbort = true;
      final pending = adapter.fetch(_options('/RSS/Classic'), null, null);
      await encrypted.started.future;
      adapter.close(force: true);
      await expectLater(pending, throwsA(isA<DioException>()));
      expect(encrypted.closed, isTrue);
      expect(encrypted.aborted, isTrue);
      expect(plain.requests, isEmpty);
    },
  );
}

RequestOptions _options(String path) => RequestOptions(
  path: 'https://mikanani.me$path',
  followRedirects: false,
  headers: {'accept': 'test'},
);

class _PlainAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  String payload = 'normal HTTPS';
  bool waitForAbort = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (waitForAbort) {
      await cancelFuture;
      throw DioException.requestCancelled(
        requestOptions: options,
        reason: 'closed',
      );
    }
    return ResponseBody.fromString(payload, 200);
  }

  @override
  void close({bool force = false}) {}
}

class _EncryptedClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final started = Completer<void>();
  bool fail = false;
  bool waitForAbort = false;
  bool stallBody = false;
  bool aborted = false;
  bool closed = false;
  int status = 200;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (!started.isCompleted) started.complete();
    if (fail) throw http.ClientException('unreachable', request.url);
    if (waitForAbort) {
      await (request as http.Abortable).abortTrigger;
      aborted = true;
      throw http.RequestAbortedException();
    }
    return http.StreamedResponse(
      stallBody
          ? _stalledBody(request as http.Abortable)
          : Stream.value('encrypted HTTPS'.codeUnits),
      status,
    );
  }

  Stream<List<int>> _stalledBody(http.Abortable request) async* {
    yield [1];
    await request.abortTrigger;
    aborted = true;
    throw http.RequestAbortedException();
  }

  @override
  void close() => closed = true;
}
