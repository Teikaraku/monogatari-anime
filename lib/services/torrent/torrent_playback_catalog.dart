import 'package:kazumi/services/api_video/api_video_models.dart';
import 'package:kazumi/services/rss/rss_release_title_parser.dart';
import 'package:kazumi/services/rss/rss_playback_resolver.dart'
    show rssEpisodeKey;
import 'torrent_models.dart';

/// A task-page file click is explicit, so even unnumbered files can play.
/// Only unambiguous episode numbers share history with RSS/API playback.
List<({ApiVideoEpisode episode, int fileIndex})> torrentPlaybackCatalog(
  TorrentTaskSnapshot task,
) {
  final files = task.files.where((file) => file.isVideo).toList();
  final numbers = files.map((file) {
    final parsed = parseRssReleaseTitle(file.name.split(RegExp(r'[/\\]')).last);
    if (parsed.isSpecial || parsed.isBatch) return null;
    return parsed.episodeNumber ??
        (files.length == 1 ? task.episodeNumber : null);
  }).toList();
  return [
    for (var i = 0; i < files.length; i++)
      (
        fileIndex: files[i].index,
        episode: ApiVideoEpisode(
          key:
              numbers[i] != null &&
                  numbers.where((number) => number == numbers[i]).length == 1
              ? rssEpisodeKey(numbers[i]!)
              : 'torrent:${task.id}:${files[i].index}',
          title: files[i].name.split(RegExp(r'[/\\]')).last,
          number:
              numbers[i] != null &&
                  numbers.where((number) => number == numbers[i]).length == 1
              ? numbers[i]
              : null,
        ),
      ),
  ];
}
