import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/utils/m3u8_ad_filter.dart';
import 'package:kazumi/utils/m3u8_parser.dart';

void main() {
  const content =
      '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:100\n'
      '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
      '#EXTINF:300,\nmain-a.ts\n#EXT-X-DISCONTINUITY\n'
      '#EXTINF:12,\nad.ts\n#EXT-X-DISCONTINUITY\n'
      '#EXTINF:1100,\nmain-b.ts\n#EXT-X-ENDLIST\n';
  test(
    'short inserted ads are removed without discarding a shorter legitimate chapter',
    () {
      final parsed = M3u8Parser.parseMediaPlaylist(
        content,
        'https://cdn.test/index.m3u8',
      );
      final filtered = M3u8AdFilter.filterAds(parsed.segments);
      expect(filtered.map((segment) => segment.uri), [
        'https://cdn.test/main-a.ts',
        'https://cdn.test/main-b.ts',
      ]);
    },
  );
  test(
    'filtering preserves original AES sequence IVs and playlist metadata',
    () {
      final result = M3u8AdFilter.filterPlaylist(
        content,
        'https://cdn.test/index.m3u8',
      );
      expect(result, isNot(contains('\nad.ts')));
      expect(result, contains('#EXT-X-MEDIA-SEQUENCE:100'));
      final reparsed = M3u8Parser.parseMediaPlaylist(
        result,
        'https://cdn.test/index.m3u8',
      );
      expect(
        reparsed.segments[0].key!.iv,
        '0x00000000000000000000000000000064',
      );
      expect(
        reparsed.segments[1].key!.iv,
        '0x00000000000000000000000000000066',
      );
    },
  );
  test('byte-range layouts are retained so implicit offsets cannot change', () {
    expect(
      M3u8AdFilter.filterPlaylist(
        content.replaceFirst('ad.ts', '#EXT-X-BYTERANGE:16\nad.ts'),
        'https://cdn.test/index.m3u8',
      ),
      contains('\nad.ts'),
    );
  });
}
