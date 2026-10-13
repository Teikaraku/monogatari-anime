import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/player_error_mapper.dart';

void main() {
  test('unsupported media advises playback retry without a source picker', () {
    final message = PlayerErrorMapper.toActionableMessage(
      'Failed to recognize file format',
      isBuffering: false,
    );
    expect(message, contains('重试播放'));
    expect(message, isNot(contains('更换')));
    expect(message, isNot(contains('规则')));
  });

  test('opening failures provide retry advice only while media is loading', () {
    expect(
      PlayerErrorMapper.toActionableMessage(
        'Failed to open',
        isBuffering: true,
      ),
      contains('重试播放'),
    );
    expect(
      PlayerErrorMapper.toActionableMessage(
        'Failed to open',
        isBuffering: false,
      ),
      isNull,
    );
  });

  test('unrelated internal diagnostics do not become actionable errors', () {
    expect(
      PlayerErrorMapper.toActionableMessage(
        'Audio decoder warning',
        isBuffering: true,
      ),
      isNull,
    );
  });
}
