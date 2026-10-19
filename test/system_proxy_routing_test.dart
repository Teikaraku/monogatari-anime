import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/system_proxy_service.dart';

void main() {
  const state = SystemProxyState(
    httpProxy: ('127.0.0.1', 7890),
    httpsProxy: ('127.0.0.1', 7891),
    bypassPatterns: ['*.direct.example', 'video.example:8443'],
    bypassLocal: true,
  );

  test('video URI chooses its own scheme instead of forcing HTTPS proxy', () {
    expect(
      state.findProxy(Uri.parse('http://cdn.example/video.m3u8')),
      'PROXY 127.0.0.1:7890',
    );
    expect(
      state.findProxy(Uri.parse('https://cdn.example/video.m3u8')),
      'PROXY 127.0.0.1:7891',
    );
  });

  test('CDN bypass rules and local readers remain direct', () {
    for (final url in [
      'https://cdn.direct.example/video.m3u8',
      'https://video.example:8443/video.m3u8',
      'http://localhost:1234/torrent/reader',
      'http://127.0.0.1:1234/torrent/reader',
      'http://media-server/video.mp4',
      'file:///video.mp4',
    ]) {
      expect(state.findProxy(Uri.parse(url)), 'DIRECT', reason: url);
    }
    expect(
      state.findProxy(Uri.parse('https://video.example/video.m3u8')),
      'PROXY 127.0.0.1:7891',
    );
    expect(
      state.findProxy(Uri.parse('https://direct.example.other/video.m3u8')),
      'PROXY 127.0.0.1:7891',
    );
  });

  test('a disabled proxy snapshot keeps public media direct', () {
    expect(
      const SystemProxyState().findProxy(
        Uri.parse('https://cdn.example/video.m3u8'),
      ),
      'DIRECT',
    );
  });
}
