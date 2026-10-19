import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:b_encode_decode/b_encode_decode.dart' as bencode;
import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final hash = String.fromCharCodes(List.filled(20, 7));

  test(
    'DHT follows router and get_peers referrals without a tracker',
    () async {
      final leaf = await _DhtNode.create(7);
      final middle = await _DhtNode.create(8);
      final router = await _DhtNode.create(9);
      leaf.reply = (query) => {
        'values': [
          Uint8List.fromList([127, 0, 0, 1, 0x1a, 0xe1]),
        ],
        'token': 'fixture',
      };
      middle.reply = (query) => {'nodes': leaf.compact};
      router.reply = (query) => query['q'] == 'find_node'
          ? {'nodes': middle.compact}
          : {'nodes': Uint8List(0)};
      // A router response after bootstrap/announce was previously only cached:
      // the next hop was never queried and playback stayed at zero peers.
      router.delay = const Duration(milliseconds: 50);
      final driver = InRepoStandaloneDHTDriver(bootstrapNodes: [router.uri]);
      driver.addressFamilyMode = StandaloneDHTAddressFamilyMode.ipv4Only;
      final discovered = driver.events
          .where((event) => event is StandaloneDHTDriverNewPeerEvent)
          .cast<StandaloneDHTDriverNewPeerEvent>()
          .first;
      try {
        await driver.bootstrap();
        driver.announce(hash, 4567);
        final event = await discovered.timeout(const Duration(seconds: 3));
        expect(event.infoHash, hash);
        expect(middle.queries, contains('get_peers'));
        expect(leaf.queries, contains('get_peers'));
      } finally {
        await driver.stop();
        await router.close();
        await middle.close();
        await leaf.close();
      }
    },
  );

  test('DHT refresh recovers when initial UDP lookup is dropped', () async {
    final router = await _DhtNode.create(1);
    var peerQueries = 0;
    router.reply = (query) {
      if (query['q'] != 'get_peers') return {'nodes': Uint8List(0)};
      if (++peerQueries == 1) return null;
      return {
        'values': [
          Uint8List.fromList([127, 0, 0, 1, 0x1a, 0xe1]),
        ],
      };
    };
    final driver = InRepoStandaloneDHTDriver(
      bootstrapNodes: [router.uri],
      queryTimeout: const Duration(milliseconds: 80),
      refreshInterval: const Duration(milliseconds: 150),
    );
    driver.addressFamilyMode = StandaloneDHTAddressFamilyMode.ipv4Only;
    final discovered = driver.events
        .where((event) => event is StandaloneDHTDriverNewPeerEvent)
        .first;
    try {
      await driver.bootstrap();
      driver.requestPeers(hash);
      await discovered.timeout(const Duration(seconds: 3));
      expect(peerQueries, greaterThanOrEqualTo(2));
      await driver.stop();
      final requestsAfterStop = router.queries.length;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(router.queries.length, requestsAfterStop);
    } finally {
      await driver.stop();
      await router.close();
    }
  });

  test('DHT ignores unsolicited referrals and peers', () async {
    final unwanted = await _DhtNode.create(3);
    final driver = InRepoStandaloneDHTDriver(bootstrapNodes: []);
    driver.addressFamilyMode = StandaloneDHTAddressFamilyMode.ipv4Only;
    final peers = <StandaloneDHTDriverEvent>[];
    final listener = driver.events.listen(peers.add);
    try {
      final port = (await driver.bootstrap())!;
      driver.requestPeers(hash);
      unwanted.socket.send(
        bencode.encode({
          't': 'zz',
          'y': 'r',
          'r': {
            'id': Uint8List.fromList(List.filled(20, 3)),
            'nodes': unwanted.compact,
            'values': [
              Uint8List.fromList([127, 0, 0, 1, 0x1a, 0xe1]),
            ],
          },
        }),
        InternetAddress.loopbackIPv4,
        port,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(unwanted.queries, isEmpty);
      expect(peers.whereType<StandaloneDHTDriverNewPeerEvent>(), isEmpty);
    } finally {
      await driver.stop();
      await listener.cancel();
      await unwanted.close();
    }
  });
}

class _DhtNode {
  final RawDatagramSocket socket;
  final int id;
  final queries = <String>[];
  final timers = <Timer>[];
  Duration delay = Duration.zero;
  Map<String, Object>? Function(Map query)? reply;
  late final StreamSubscription<RawSocketEvent> subscription;
  _DhtNode(this.socket, this.id) {
    subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final incoming = datagram!;
        final query = bencode.decode(incoming.data) as Map;
        expect(query['t'], isA<Uint8List>());
        final args = query['a'] as Map;
        expect(args['id'], isA<Uint8List>());
        if (args.containsKey('info_hash')) {
          expect(args['info_hash'], isA<Uint8List>());
          expect((args['info_hash'] as Uint8List).length, 20);
        }
        query['q'] = String.fromCharCodes(query['q'] as List<int>);
        queries.add(query['q'] as String);
        final body = reply?.call(query);
        if (body == null) continue;
        timers.add(
          Timer(delay, () {
            socket.send(
              bencode.encode({
                't': query['t'],
                'y': 'r',
                'r': {'id': Uint8List.fromList(List.filled(20, id)), ...body},
              }),
              incoming.address,
              incoming.port,
            );
          }),
        );
      }
    });
  }

  static Future<_DhtNode> create(int id) async => _DhtNode(
    await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
    id,
  );

  Uri get uri => Uri.parse('udp://127.0.0.1:${socket.port}');
  Uint8List get compact => Uint8List.fromList([
    ...List.filled(20, id),
    127,
    0,
    0,
    1,
    socket.port >> 8,
    socket.port & 255,
  ]);

  Future<void> close() async {
    for (final timer in timers) {
      timer.cancel();
    }
    await subscription.cancel();
    socket.close();
  }
}
