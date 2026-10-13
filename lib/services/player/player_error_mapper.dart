class PlayerErrorMapper {
  const PlayerErrorMapper._();

  static String? toActionableMessage(
    Object error, {
    required bool isBuffering,
  }) {
    final message = error.toString();
    if (message.contains('Failed to recognize file format') ||
        (isBuffering && message.contains('Failed to open'))) {
      return '当前视频资源加载失败，请重试播放';
    }
    return null;
  }
}
