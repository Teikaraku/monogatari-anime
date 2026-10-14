import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:b_encode_decode/b_encode_decode.dart' as bencode;
import 'package:crypto/crypto.dart';

/// A real BEP 3 TCP seeder, BEP 9 metadata peer and compact HTTP tracker.
/// It serves deterministic fixture bytes; the production BT engine performs
/// the handshake, peer requests, piece hash verification and disk writes.
class TorrentLoopbackFixture {
  final Uint8List data;
  final String name;
  final int pieceLength;
  final List<(String, int)>? files;
  final withheld = <int>{};
  final requests = <int>[];
  final _waiting = <int, List<void Function()>>{};
  final _sockets = <Socket>{};
  late HttpServer tracker;
  late ServerSocket seeder;
  late Uint8List infoBytes;
  late Uint8List torrentBytes;
  late Uint8List infoHash;
  int? advertisedMetadataSize;
  List<(InternetAddress, int)> extraPeers = [];
  Duration handshakeDelay = Duration.zero;
  String peerId = '-MO0001-012345678901';

  TorrentLoopbackFixture({
    required this.data,
    this.name = 'movie.mp4',
    this.pieceLength = 16384,
    this.files,
  });

  Uri get source =>
      Uri.parse('http://127.0.0.1:${tracker.port}/fixture.torrent');
  Uri get magnet => Uri.parse(
    'magnet:?xt=urn:btih:${sha1.convert(infoBytes)}&tr=${Uri.encodeQueryComponent('http://127.0.0.1:${tracker.port}/announce')}',
  );

  Future<void> start() async {
    seeder = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    tracker = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final hashes = BytesBuilder(copy: false);
    for (var offset = 0; offset < data.length; offset += pieceLength) {
      hashes.add(
        sha1
            .convert(
              data.sublist(offset, min(offset + pieceLength, data.length)),
            )
            .bytes,
      );
    }
    final info = <String, dynamic>{
      'name': name,
      'piece length': pieceLength,
      'pieces': hashes.takeBytes(),
    };
    if (files == null) {
      info['length'] = data.length;
    } else {
      info['files'] = files!
          .map((file) => {'path': file.$1.split('/'), 'length': file.$2})
          .toList();
    }
    infoBytes = bencode.encode(info);
    infoHash = Uint8List.fromList(sha1.convert(infoBytes).bytes);
    torrentBytes = bencode.encode({
      'info': info,
      'announce': 'http://127.0.0.1:${tracker.port}/announce',
    });
    seeder.listen(_accept);
    tracker.listen((request) async {
      if (request.uri.path == '/fixture.torrent') {
        request.response.add(torrentBytes);
      } else {
        request.response.add(
          bencode.encode({
            'interval': 60,
            'complete': 1,
            'incomplete': 0,
            'peers': Uint8List.fromList([
              127,
              0,
              0,
              1,
              seeder.port >> 8,
              seeder.port & 255,
              for (final peer in extraPeers) ...[
                ...peer.$1.rawAddress,
                peer.$2 >> 8,
                peer.$2 & 255,
              ],
            ]),
          }),
        );
      }
      await request.response.close();
    });
  }

  void release(int piece) {
    withheld.remove(piece);
    for (final send in _waiting.remove(piece) ?? []) {
      send();
    }
  }

  void _accept(Socket socket) {
    _sockets.add(socket);
    var pending = <int>[];
    var handshake = false;
    var metadataId = 1;
    final subscription = socket.listen(
      (block) {
        pending.addAll(block);
        if (!handshake) {
          if (pending.length < 68) return;
          if (pending.sublist(28, 48).toString() != infoHash.toString()) {
            stdout.writeln(
              'fixture infohash mismatch: actual=${pending.sublist(28, 48)} expected=$infoHash',
            );
            socket.destroy();
            return;
          }
          pending = pending.sublist(68);
          handshake = true;
          final reserved = Uint8List(8)..[5] = 0x10;
          socket.add([
            19,
            ...ascii.encode('BitTorrent protocol'),
            ...reserved,
            ...infoHash,
            ...ascii.encode(peerId),
          ]);
          final pieces = (data.length + pieceLength - 1) ~/ pieceLength;
          final bitfield = Uint8List((pieces + 7) ~/ 8);
          for (var piece = 0; piece < pieces; piece++) {
            bitfield[piece ~/ 8] |= 128 >> (piece % 8);
          }
          socket.add(_frame(5, bitfield));
          socket.add(_frame(1, []));
          socket.add(
            _frame(20, [
              0,
              ...bencode.encode({
                'm': {'ut_metadata': 1},
                'metadata_size': advertisedMetadataSize ?? infoBytes.length,
              }),
            ]),
          );
        }
        while (pending.length >= 4) {
          final length = ByteData.sublistView(
            Uint8List.fromList(pending),
            0,
            4,
          ).getUint32(0);
          if (length > 1024 * 1024) {
            socket.destroy();
            return;
          }
          if (pending.length < length + 4) return;
          final payload = Uint8List.fromList(pending.sublist(4, length + 4));
          pending = pending.sublist(length + 4);
          if (payload.isEmpty) continue;
          if (payload[0] == 6 && payload.length == 13) {
            final values = ByteData.sublistView(payload, 1);
            final piece = values.getUint32(0),
                begin = values.getUint32(4),
                size = values.getUint32(8);
            final start = piece * pieceLength + begin;
            if (size > 16384 || start + size > data.length) {
              socket.destroy();
              return;
            }
            requests.add(piece);
            void send() {
              if (!_sockets.contains(socket)) return;
              final header = ByteData(8)
                ..setUint32(0, piece)
                ..setUint32(4, begin);
              socket.add(
                _frame(7, [
                  ...header.buffer.asUint8List(),
                  ...data.sublist(start, start + size),
                ]),
              );
            }

            if (withheld.contains(piece)) {
              _waiting.putIfAbsent(piece, () => []).add(send);
            } else {
              send();
            }
          } else if (payload[0] == 20 && payload.length > 2) {
            try {
              final message = bencode.decode(payload.sublist(2));
              if (message is! Map) continue;
              if (payload[1] == 0) {
                final remote = message['m'];
                if (remote is Map && remote['ut_metadata'] is int) {
                  metadataId = remote['ut_metadata'] as int;
                }
              } else if (message['msg_type'] == 0) {
                final piece = message['piece'] as int;
                final start = piece * 16384;
                if (start >= infoBytes.length) continue;
                socket.add(
                  _frame(20, [
                    metadataId,
                    ...bencode.encode({
                      'msg_type': 1,
                      'piece': piece,
                      'total_size': infoBytes.length,
                    }),
                    ...infoBytes.sublist(
                      start,
                      min(start + 16384, infoBytes.length),
                    ),
                  ]),
                );
              }
            } catch (_) {}
          }
        }
      },
      onError: (Object _) {
        _sockets.remove(socket);
        socket.destroy();
      },
      onDone: () {
        _sockets.remove(socket);
        socket.destroy();
      },
    );
    if (handshakeDelay > Duration.zero) {
      subscription.pause();
      Timer(handshakeDelay, subscription.resume);
    }
  }

  List<int> _frame(int id, List<int> data) {
    final length = ByteData(4)..setUint32(0, data.length + 1);
    return [...length.buffer.asUint8List(), id, ...data];
  }

  Future<void> close() async {
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
    await seeder.close();
    await tracker.close(force: true);
  }
}
