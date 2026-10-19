import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';

/// Opt-in foreground polling. Constructors and repository initialization do
/// not start timers or network requests; the application starts this explicitly.
class RssRefreshCoordinator with WidgetsBindingObserver {
  RssRefreshCoordinator({
    required this.refresh,
    required this.hasEnabledSubscriptions,
    this.interval = const Duration(minutes: 15),
    DateTime? lastRefreshAt,
    DateTime Function()? clock,
    this.observeAppLifecycle = true,
  }) : _lastAttempt = lastRefreshAt,
       _clock = clock ?? DateTime.now;
  final Future<void> Function(CancelToken token) refresh;
  final bool Function() hasEnabledSubscriptions;
  final Duration interval;
  final DateTime Function() _clock;
  final bool observeAppLifecycle;
  DateTime? _lastAttempt;
  Timer? _timer;
  CancelToken? _active;
  bool _foreground = true;
  bool _started = false;
  bool _disposed = false;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    if (observeAppLifecycle) {
      final binding = WidgetsBinding.instance;
      _foreground =
          binding.lifecycleState == null ||
          binding.lifecycleState == AppLifecycleState.resumed;
      binding.addObserver(this);
    }
    _schedule();
    unawaited(refreshIfDue());
  }

  Future<void> refreshIfDue() async {
    if (!_started ||
        _disposed ||
        !_foreground ||
        _active != null ||
        !hasEnabledSubscriptions()) {
      return;
    }
    if (_lastAttempt != null && _clock().difference(_lastAttempt!) < interval) {
      return;
    }
    final token = CancelToken();
    _active = token;
    _lastAttempt = _clock();
    try {
      await refresh(token);
    } catch (_) {
      /* Service exposes failures; a timer must not throw into UI. */
    } finally {
      if (identical(_active, token)) _active = null;
    }
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (_started && !_disposed && _foreground) {
      final remaining = _lastAttempt == null
          ? interval
          : interval - _clock().difference(_lastAttempt!);
      _timer = Timer(remaining > Duration.zero ? remaining : interval, () {
        unawaited(refreshIfDue().whenComplete(_schedule));
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      if (_active != null) {
        _active!.cancel('应用已进入后台');
        _active = null;
        _lastAttempt = null;
      }
      _timer?.cancel();
      _timer = null;
    } else {
      _schedule();
      unawaited(refreshIfDue());
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _active?.cancel('RSS 自动刷新已停止');
    if (_started && observeAppLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
    }
  }
}
