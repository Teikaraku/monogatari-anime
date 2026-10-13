import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/torrent/torrent_models.dart';
import 'package:kazumi/services/torrent/torrent_playback_catalog.dart';

void main() {
  TorrentTaskSnapshot task(List<String> names, {double? number}) =>
      TorrentTaskSnapshot(
        id: 'hash',
        source: Uri.parse('magnet:?xt=urn:btih:hash'),
        title: '测试',
        state: TorrentTaskState.paused,
        episodeNumber: number,
        files: [
          for (var i = 0; i < names.length; i++)
            TorrentFileInfo(index: i, name: names[i], size: 100, isVideo: true),
        ],
      );
  test(
    'batch file order preserves exact clicked file identity and shared history keys',
    () {
      final entries = torrentPlaybackCatalog(
        task(['Show - 03.mkv', 'Show - 01.mkv', 'Show - 02.mkv']),
      );
      expect(entries.map((e) => e.episode.key), ['3', '1', '2']);
      expect(entries[2].fileIndex, 2);
    },
  );
  test(
    'duplicate encodes and unknown files remain individually selectable',
    () {
      final entries = torrentPlaybackCatalog(
        task(['Show - 02 [720p].mkv', 'Show - 02 [1080p].mkv', 'opaque.mkv']),
      );
      expect(entries.map((e) => e.episode.key).toSet().length, 3);
      expect(entries.every((e) => e.episode.number == null), isTrue);
    },
  );
  test('only an opaque singleton inherits the verified release episode', () {
    expect(
      torrentPlaybackCatalog(
        task(['opaque.mkv'], number: 3),
      ).single.episode.number,
      3,
    );
    expect(
      torrentPlaybackCatalog(
        task(['opaque.mkv', 'other.mkv'], number: 3),
      ).every((e) => e.episode.number == null),
      isTrue,
    );
    expect(
      torrentPlaybackCatalog(
        task(['Show SP01.mkv'], number: 3),
      ).single.episode.number,
      isNull,
    );
  });
}
