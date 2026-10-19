import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/bangumi_image_url_rewriter.dart';

void main() {
  group('BangumiImageUrlRewriter', () {
    test('bypasses stalled resizing without changing origin or revision', () {
      for (final kind in ['cover', 'crt']) {
        final uri = Uri.parse(
          'https://lain.bgm.tv/r/200/pic/$kind/l/a.jpg?r=123',
        );
        expect(
          BangumiImageUrlRewriter.originalImage(uri).toString(),
          'https://lain.bgm.tv/pic/$kind/l/a.jpg?r=123',
        );
        expect(
          _rewrite(uri).toString(),
          'https://relay.example.test/img/pic/$kind/l/a.jpg?r=123',
        );
      }
      final other = Uri.parse('https://other.test/r/200/pic/cover/l/a.jpg');
      expect(BangumiImageUrlRewriter.originalImage(other), other);
    });
    test('routes lain images through the relay image cache', () {
      expect(
        _rewrite(Uri.parse('https://lain.bgm.tv/pic/cover/l/cover.jpg'))
            .toString(),
        'https://relay.example.test/img/pic/cover/l/cover.jpg',
      );
      expect(
        _rewrite(Uri.parse('https://lain.bgm.tv/pic/cover/l/animated.gif'))
            .toString(),
        'https://relay.example.test/img/pic/cover/l/animated.gif',
      );
    });

    test('routes API image endpoints through the relay', () {
      for (final type in ['subjects', 'characters', 'persons']) {
        final source = 'https://api.bgm.tv/v0/$type/590353/image?type=large';
        expect(
          _rewrite(Uri.parse(source)).toString(),
          'https://relay.example.test/v0/$type/590353/image?type=large',
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
        expect(_rewrite(Uri.parse(url)).toString(), url);
      }
    });
  });
}

Uri _rewrite(Uri uri) => BangumiImageUrlRewriter.rewrite(
  uri,
  relayOrigin: 'https://relay.example.test',
);
