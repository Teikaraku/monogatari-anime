import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/api_video/api_video_service.dart';
import 'package:kazumi/services/api_video/api_video_url_policy.dart';
import 'package:kazumi/services/api_video/episode_identity.dart';
import 'api_video_service_test.dart' as fixture;

void main() {
  test(
    'unreachable providers have a short cooldown across titles; explicit refresh retries immediately',
    () async {
      var calls = 0;
      var now = DateTime(2026);
      final api = ApiVideoService(
        clock: () => now,
        transport: (_, _) async {
          calls++;
          throw const SocketException('unreachable');
        },
      );
      for (final name in ['作品一', '作品二']) {
        await expectLater(
          api.loadCatalog(fixture.subject(name: name)),
          throwsA(isA<ApiVideoUnavailableException>()),
        );
      }
      expect(calls, 6); // Three providers, one reconnect each, then cooldown.
      now = now.add(const Duration(seconds: 16));
      await expectLater(
        api.loadCatalog(fixture.subject(name: '作品三')),
        throwsA(isA<ApiVideoUnavailableException>()),
      );
      expect(calls, 12);
      api.clearCache();
      await expectLater(
        api.loadCatalog(fixture.subject(name: '作品三')),
        throwsA(isA<ApiVideoUnavailableException>()),
      );
      expect(calls, 18);
    },
  );
  test('a sole namesake from the wrong year is never selected', () async {
    final api = ApiVideoService(
      transport: (_, _) async =>
          fixture.document([fixture.row(name: '鬼太郎', year: '1968')]),
    );
    await expectLater(
      api.loadCatalog(fixture.subject(name: '鬼太郎', airDate: '2018-04-01')),
      throwsA(
        isA<ApiVideoUnavailableException>().having(
          (e) => e.failure,
          'missing, not network',
          isNull,
        ),
      ),
    );
  });

  test('site-specific SP labels share one identity across providers', () async {
    final api = ApiVideoService(
      transport: (url, _) async => fixture.document([
        fixture.row(
          entries: url.host == 'api.yzzy-api.com'
              ? r'SP01$https://cdn.test/sp.m3u8'
              : r'特别篇1$https://other.test/sp.mp4',
        ),
      ]),
    );
    final catalog = await api.loadCatalog(fixture.subject());
    final candidates = await api
        .candidatesForEpisode(fixture.subject(), catalog.episodes.single)
        .toList();
    expect(candidates, hasLength(3));
    expect(
      candidates.map((entry) => entry.episode.key),
      everyElement('special:sp:1'),
    );
    expect(
      episodeHistorySlot('monogatari://episode/42/rss-special%3Asp1', 1),
      episodeHistorySlot('monogatari://episode/42/special%3Asp01', 5),
    );
    expect(episodeHistorySlot('monogatari://episode/42/11', 1), 11);
  });

  test(
    'transport failures retain their reason through cached fallback results',
    () async {
      for (final failure in [
        ApiVideoFailure.network,
        ApiVideoFailure.timeout,
        ApiVideoFailure.blocked,
      ]) {
        final api = ApiVideoService(
          transport: (_, _) async {
            if (failure == ApiVideoFailure.network)
              throw const SocketException('offline');
            if (failure == ApiVideoFailure.timeout)
              throw TimeoutException('timed out');
            return '<html>verification</html>';
          },
        );
        for (var attempt = 0; attempt < 2; attempt++) {
          await expectLater(
            api.loadCatalog(fixture.subject()),
            throwsA(
              isA<ApiVideoUnavailableException>().having(
                (e) => e.failure,
                'reason',
                failure,
              ),
            ),
          );
        }
      }
    },
  );

  test(
    'oversized responses stop at the byte limit before JSON decoding',
    () async {
      var cancelled = false;
      final dio = Dio()
        ..httpClientAdapter = _Adapter((options, cancellation) async {
          cancellation?.then((_) => cancelled = true);
          return ResponseBody(Stream.value(Uint8List(1025)), 200);
        });
      addTearDown(() => dio.close(force: true));
      await expectLater(
        ApiVideoService(
          dio: dio,
          maxResponseBytes: 1024,
        ).loadCatalog(fixture.subject()),
        throwsA(
          isA<ApiVideoUnavailableException>().having(
            (e) => e.failure,
            'limit',
            ApiVideoFailure.invalidResponse,
          ),
        ),
      );
      expect(cancelled, isTrue);
    },
  );

  test(
    'large valid JSON is decoded by the worker and remains playable',
    () async {
      final payload = jsonEncode(
        fixture.document([
          {...fixture.row(), 'desc': 'x' * (128 * 1024)},
        ]),
      );
      final dio = Dio()
        ..httpClientAdapter = _Adapter(
          (options, _) async => ResponseBody.fromString(payload, 200),
        );
      addTearDown(() => dio.close(force: true));
      final catalog = await ApiVideoService(
        dio: dio,
      ).loadCatalog(fixture.subject());
      expect(catalog.episodes.map((episode) => episode.number), [1, 2]);
    },
  );

  test(
    'untrusted media cannot use cleartext, private hosts or hidden credentials',
    () async {
      for (final url in [
        'http://cdn.test/1.m3u8',
        'https://localhost/1.mp4',
        'https://127.0.0.1/1.mp4',
        'https://10.0.0.1/1.mp4',
        'https://192.168.1.1/1.mp4',
        'https://[::1]/1.mp4',
        'https://[::ffff:127.0.0.1]/1.mp4',
        'https://user:pass@cdn.test/1.mp4',
        'https://router.local/1.mp4',
      ]) {
        expect(isPublicVideoUri(Uri.parse(url)), isFalse, reason: url);
      }
      await expectLater(
        validatePublicVideoUri(
          Uri.parse('https://cdn.test/a.mp4'),
          lookup: (_) async => [InternetAddress('192.168.1.2')],
        ),
        throwsFormatException,
      );
    },
  );
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final Future<ResponseBody> Function(RequestOptions, Future<void>?) reply;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelled,
  ) => reply(options, cancelled);
  @override
  void close({bool force = false}) {}
}
