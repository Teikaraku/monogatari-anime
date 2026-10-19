import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_subject_detail.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';

void main() {
  test('parses the p1 subject fields the detail page shows', () {
    final detail = BangumiSubjectDetail.fromJson({
      'platform': {'type': 'TV', 'typeCN': 'TV'},
      'metaTags': ['TV', '日本', '漫画改', '萌系', ' '],
      'eps': 12,
      'airtime': {'date': '2026-10-01', 'weekday': 4},
      'infobox': [
        {
          'key': '别名',
          'values': [
            {'v': 'FX Fighter Kurumi-chan'},
            {'v': ''},
          ],
        },
        {
          'key': '链接',
          'values': [
            {'k': 'X', 'v': 'https://x.com/fxkurumi_info'},
          ],
        },
        {'key': '空', 'values': []},
      ],
    });

    expect(detail.platform, 'TV');
    expect(detail.metaTags, ['TV', '日本', '漫画改', '萌系']);
    expect(detail.categories, ['日本', '漫画改', '萌系']);
    expect(detail.totalEpisodes, 12);
    expect(detail.airWeekday, 4);
    expect(detail.infobox.map((field) => field.key), ['别名', '链接']);
    expect(detail.field('别名')!.values.single.value, 'FX Fighter Kurumi-chan');
    final link = detail.field('链接')!.values.single;
    expect(link.label, 'X');
    expect(link.link?.host, 'x.com');
  });

  test('accepts v0 infobox values and missing fields', () {
    final detail = BangumiSubjectDetail.fromJson({
      'platform': '剧场版',
      'meta_tags': ['剧场版', '原创'],
      'infobox': [
        {'key': '片长', 'value': '120分钟'},
        {
          'key': '别名',
          'value': [
            {'v': 'Alias'},
          ],
        },
        {'key': '官方网站', 'value': 'not a url'},
      ],
    });

    expect(detail.platform, '剧场版');
    expect(detail.categories, ['原创']);
    expect(detail.totalEpisodes, 0);
    expect(detail.airWeekday, 0);
    expect(detail.field('片长')!.values.single.value, '120分钟');
    expect(detail.field('别名')!.values.single.value, 'Alias');
    expect(detail.field('官方网站')!.values.single.link, isNull);

    final empty = BangumiSubjectDetail.fromJson(const {});
    expect(empty.platform, isEmpty);
    expect(empty.metaTags, isEmpty);
    expect(empty.infobox, isEmpty);
  });

  test('episodes expose their air day and in-season number', () {
    final aired = EpisodeInfo.fromJson({
      'id': 1,
      'sort': 13,
      'ep': 1,
      'type': 0,
      'name': 'FXって、なぁに？',
      'name_cn': 'FX⋯是什么？',
      'airdate': '2026-10-01',
      'duration': '00:23:45',
      'desc': 'summary',
      'comment': 235,
    });
    expect(aired.displayNumber, 1);
    expect(aired.airDay, DateTime(2026, 10, 1));
    expect(aired.commentCount, 235);

    final undated = EpisodeInfo.fromJson({'id': 2, 'sort': 2, 'airdate': ''});
    expect(undated.displayNumber, 2);
    expect(undated.airDay, isNull);
    expect(EpisodeInfo.fromJson({'airdate': '2026-13-40'}).airDay, isNull);
  });
}
