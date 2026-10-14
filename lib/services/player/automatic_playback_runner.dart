import 'dart:async';

/// Keeps a single episode on the next usable resource without changing its
/// identity or presenting a source picker. A new episode cancels the old run.
class AutomaticPlaybackRunner<T> {
  AutomaticPlaybackRunner({
    required this.open,
    required this.stop,
    required this.onAttempt,
    required this.onReady,
    required this.onExhausted,
    required this.currentOffset,
    this.onFailure,
  });

  final Future<bool> Function(T candidate, int offset) open;
  final Future<void> Function() stop;
  final void Function(T candidate) onAttempt;
  final void Function(T candidate) onReady;
  final void Function() onExhausted;
  final int Function() currentOffset;
  final void Function(Object error)? onFailure;

  StreamIterator<T>? _candidates;
  int _generation = 0;
  bool _switching = false;

  Future<bool> start(Stream<T> candidates, {int offset = 0}) async {
    final cancellation = cancel();
    final generation = _generation;
    await cancellation;
    if (generation != _generation) return false;
    _candidates = StreamIterator(candidates);
    return _advance(generation, offset);
  }

  Future<bool> recover() {
    if (_switching || _candidates == null) return Future.value(false);
    return _advance(_generation, currentOffset());
  }

  Future<bool> _advance(int generation, int offset) async {
    final candidates = _candidates;
    if (candidates == null || generation != _generation) return false;
    _switching = true;
    try {
      while (await candidates.moveNext()) {
        if (generation != _generation) return false;
        try {
          await stop();
        } catch (_) {
          // Native ownership is detached before disposal/audio cleanup waits.
          // A cleanup failure must not discard an otherwise usable fallback.
        }
        if (generation != _generation) return false;
        final candidate = candidates.current;
        onAttempt(candidate);
        bool playable;
        try {
          playable = await open(candidate, offset);
        } catch (error) {
          onFailure?.call(error);
          playable = false;
        }
        if (generation != _generation) return false;
        if (playable) {
          onReady(candidate);
          return true;
        }
      }
      if (generation == _generation) {
        _candidates = null;
        onExhausted();
      }
      return false;
    } catch (error) {
      if (generation == _generation) {
        onFailure?.call(error);
        _candidates = null;
        onExhausted();
      }
      return false;
    } finally {
      if (generation == _generation) _switching = false;
    }
  }

  Future<void> cancel() async {
    _generation++;
    _switching = false;
    final candidates = _candidates;
    _candidates = null;
    try {
      await candidates?.cancel();
    } catch (_) {}
  }

  static bool isFatalMediaError(String error) {
    final message = error.toLowerCase();
    return const [
      'failed to open',
      'failed to recognize file format',
      'error opening',
      'could not open',
      'failed to read',
      'http error',
      'server returned 4',
      'server returned 5',
      'connection refused',
      'connection timed out',
      'connection reset',
      'ffurl_read returned',
      'network is unreachable',
      'failed host lookup',
      'tls handshake',
      'no playable streams',
      'no video or audio streams',
      'moov atom not found',
      'invalid data found',
    ].any(message.contains);
  }
}
