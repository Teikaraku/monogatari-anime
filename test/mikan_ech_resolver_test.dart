import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kazumi/services/network/mikan_ech_resolver.dart';

void main() {
  test(
    'current edge hints are shared, verified and split between attempts',
    () async {
      final requests = <http.Request>[];
      final discovery = MikanEchDiscovery(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'Status': 0,
              'Answer': [
                {
                  'type': 65,
                  'TTL': 300,
                  'data':
                      '1 . ech="AAT+DQAA" ipv4hint="10.0.0.1,162.159.135.79,162.159.136.79"',
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(discovery.close);
      final uri = Uri.parse(
        'https://mikanani.me/RSS/MyBangumi?token=private-token',
      );
      final routes = await Future.wait([
        MikanEchResolver(discovery, 0).resolve(uri),
        MikanEchResolver(discovery, 1).resolve(uri),
      ]);
      expect(routes[0]!.addresses, ['162.159.135.79']);
      expect(routes[1]!.addresses, ['162.159.136.79']);
      expect(requests, hasLength(1));
      expect(requests.single.url.toString(), isNot(contains('private-token')));
      await discovery.discover();
      expect(requests, hasLength(1));
      expect(
        await MikanEchResolver(
          discovery,
          0,
        ).resolve(Uri.parse('https://other.test')),
        isNull,
      );
    },
  );

  test('DNS answers without public edge hints fail safely', () async {
    final discovery = MikanEchDiscovery(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'Status': 0,
            'Answer': [
              {
                'type': 65,
                'TTL': 300,
                'data': '1 . ech="AQI=" ipv4hint="127.0.0.1,10.0.0.1"',
              },
            ],
          }),
          200,
        ),
      ),
    );
    addTearDown(discovery.close);
    await expectLater(discovery.discover(), throwsFormatException);
  });
}
