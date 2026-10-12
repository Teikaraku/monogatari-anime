import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/bangumi_image_url_rewriter.dart';

void main() {
  group('BangumiImageUrlRewriter', () {
    test('routes lain images through the relay image cache', () {
      expect(
        BangumiImageUrlRewriter.rewrite(
          Uri.parse('https://lain.bgm.tv/pic/cover/l/cover.jpg'),
        ).toString(),
        'https://bgm.monogatari.top/img/pic/cover/l/cover.jpg',
      );
      expect(
        BangumiImageUrlRewriter.rewrite(
          Uri.parse('https://lain.bgm.tv/pic/cover/l/animated.gif'),
        ).toString(),
        'https://bgm.monogatari.top/img/pic/cover/l/animated.gif',
      );
    });

    test('routes API image endpoints through the relay', () {
      for (final type in ['subjects', 'characters', 'persons']) {
        final source = 'https://api.bgm.tv/v0/$type/590353/image?type=large';
        expect(
          BangumiImageUrlRewriter.rewrite(Uri.parse(source)).toString(),
          'https://bgm.monogatari.top/v0/$type/590353/image?type=large',
        );
      }
    });

    test('rejects URLs outside the image boundary', () {
      for (final url in [
        'ftp://lain.bgm.tv/pic/cover/l/cover.jpg',
        'https://api.bgm.tv/v0/subjects/590353',
        'https://api.bgm.tv/v0/subjects/not-an-id/image?type=large',
        'https://api.bgm.tv/v0/episodes/1/image?type=large',
        'https://example.com/v0/subjects/590353/image?type=large',
      ]) {
        expect(BangumiImageUrlRewriter.rewrite(Uri.parse(url)).toString(), url);
      }
    });
  });
}
