import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/api_video/api_video_models.dart';
import 'package:kazumi/services/rss/rss_models.dart';
import 'package:kazumi/services/rss/rss_playback_resolver.dart';
import 'package:kazumi/services/torrent/torrent_models.dart';

RssRelease release(
  String key, {
  double? number,
  List<double> batch = const [],
  bool special = false,
  DateTime? date,
}) => RssRelease(
  key: key,
  title: key,
  detailUri: Uri.parse('https://mikanani.me/Home/Episode/$key'),
  torrentUri: Uri.parse('https://mikanani.me/Download/$key.torrent'),
  episodeNumber: number,
  episodeNumbers: batch,
  isBatch: batch.isNotEmpty,
  isSpecial: special,
  specialKey: special ? 'sp1' : null,
  publishedAt: date,
);
TorrentFileInfo file(int index, String name) =>
    TorrentFileInfo(index: index, name: name, size: 1024, isVideo: true);
const episode = ApiVideoEpisode(key: '2', title: '第二话', number: 2);

void main() {
  test(
    'stable main episode identities match API history and merge batches',
    () {
      final episodes = rssEpisodes([
        release('pack', batch: [1, 2, 3]),
        release('single', number: 2),
        release('half', number: 1.5),
        release('extra', special: true),
      ]);
      expect(episodes.map((e) => e.key), [
        '1',
        '1.5',
        '2',
        '3',
        'rss-special:sp1',
      ]);
      expect(apiEpisodePageUrl(42, episodes[2]), 'monogatari://episode/42/2');
    },
  );
  test('unknown release never receives an invented number', () {
    expect(rssEpisodes([release('unidentified')]), isEmpty);
  });
  test(
    'single release preferred to larger batch and latest revision preferred',
    () {
      final selected = selectRssRelease([
        release('pack', batch: [1, 2], date: DateTime(2026, 10)),
        release('old', number: 2, date: DateTime(2026, 1)),
        release('revised', number: 2, date: DateTime(2026, 2)),
      ], episode);
      expect(selected.key, 'revised');
    },
  );
  test('explicit release must exist and match the requested episode', () {
    final releases = [release('one', number: 1), release('two', number: 2)];
    expect(
      () => selectRssRelease(releases, episode, releaseId: 'one'),
      throwsA(isA<RssException>()),
    );
    expect(
      () => selectRssRelease(releases, episode, releaseId: 'another-group'),
      throwsA(isA<RssException>()),
    );
    expect(selectRssRelease(releases, episode, releaseId: 'two').key, 'two');
  });
  test('batch selection finds exact video instead of archive position', () {
    final files = [
      file(0, 'Show - 03.mkv'),
      file(1, 'Show - 01.mkv'),
      file(2, '[Group] Show - 02 [1080p].mkv'),
    ];
    expect(
      selectRssVideoFile(
        files,
        release('pack', batch: [1, 2, 3]),
        episode,
      ).index,
      2,
    );
  });
  test('ambiguous batch cannot fall back to the only video', () {
    expect(
      () => selectRssVideoFile(
        [file(0, 'opaque.mkv')],
        release('pack', batch: [1, 2]),
        episode,
      ),
      throwsA(isA<RssException>()),
    );
  });
  test('single episode with opaque filename can play', () {
    expect(
      selectRssVideoFile(
        [file(0, 'opaque.mkv')],
        release('two', number: 2),
        episode,
      ).index,
      0,
    );
  });
  test('conflicting single filename cannot play the wrong episode', () {
    expect(
      () => selectRssVideoFile(
        [file(0, 'Show - 03.mkv')],
        release('two', number: 2),
        episode,
      ),
      throwsA(isA<RssException>()),
    );
  });
  test(
    'a single video explicitly named as a batch cannot masquerade as a single episode',
    () {
      expect(
        () => selectRssVideoFile(
          [file(0, 'Show [01-12].mkv')],
          release('two', number: 2),
          episode,
        ),
        throwsA(isA<RssException>()),
      );
    },
  );
  test('special release cannot play a different explicitly named special', () {
    expect(
      () => selectRssVideoFile(
        [file(0, 'Show SP02.mkv')],
        release('extra', special: true),
        const ApiVideoEpisode(key: 'rss-special:sp1', title: 'SP1'),
      ),
      throwsA(isA<RssException>()),
    );
  });
  test('samples and opening credits are never selected as the episode', () {
    final files = [
      file(0, 'sample/Show - 02.mkv'),
      file(1, 'Show NCOP02.mkv'),
      file(2, 'Show - 02.mkv'),
    ];
    expect(
      selectRssVideoFile(files, release('pack', batch: [1, 2]), episode).index,
      2,
    );
  });
  test('duplicate video encodes require an unambiguous release', () {
    expect(
      () => selectRssVideoFile(
        [file(0, 'Show - 02 [720p].mkv'), file(1, 'Show - 02 [1080p].mkv')],
        release('pack', batch: [1, 2]),
        episode,
      ),
      throwsA(isA<RssException>()),
    );
  });
  test('fractional episodes are not confused with main episodes', () {
    const half = ApiVideoEpisode(key: '2.5', title: '2.5', number: 2.5);
    final selected = selectRssVideoFile(
      [file(0, 'Show - 02.mkv'), file(1, 'Show - 02.5.mkv')],
      release('half', number: 2.5),
      half,
    );
    expect(selected.index, 1);
  });
}
