import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';

import 'mikan_rss_client.dart';
import 'rss_subscription_repository.dart';
import 'rss_refresh_coordinator.dart';

export 'rss_models.dart';
export 'rss_subscription_repository.dart';

class RssSubscriptionService extends ChangeNotifier {
  RssSubscriptionService({
    MikanRssClient? client,
    RssSubscriptionRepository? repository,
    DateTime Function()? clock,
  }) : _client = client ?? MikanRssClient(),
       _repository = repository ?? HiveRssSubscriptionRepository(),
       _clock = clock ?? DateTime.now;
  final MikanRssClient _client;
  final RssSubscriptionRepository _repository;
  final DateTime Function() _clock;
  Future<void>? _initializing;
  final List<RssSubscription> _subscriptions = [];
  final List<RssRelease> _releases = [];
  final Map<int, String> _selected = {};
  final Map<String, int> _revisions = {};
  final Set<CancelToken> _operations = {};
  int _loading = 0;
  bool _disposed = false;
  String? _lastError;
  RssRefreshCoordinator? _autoRefresh;

  List<RssSubscription> get subscriptions => List.unmodifiable(_subscriptions);
  List<RssRelease> get releases => List.unmodifiable(_releases);
  bool get isLoading => _loading > 0;
  String? get lastError => _lastError;

  Future<void> initialize() =>
      _initializing ??= _load().catchError((Object error, StackTrace stack) {
        _initializing = null;
        Error.throwWithStackTrace(error, stack);
      });
  Future<void> startAutoRefresh() async {
    await initialize();
    if (_disposed || _autoRefresh != null) return;
    final times =
        _subscriptions
            .where((value) => value.enabled)
            .map((value) => value.lastRefreshedAt)
            .whereType<DateTime>()
            .toList()
          ..sort();
    _autoRefresh = RssRefreshCoordinator(
      refresh: (token) => refresh(cancelToken: token),
      hasEnabledSubscriptions: () =>
          _subscriptions.any((value) => value.enabled),
      lastRefreshAt: times.firstOrNull,
      clock: _clock,
    )..start();
  }

  Future<void> _load() async {
    final state = await _repository.load();
    if (_disposed) return;
    _subscriptions.addAll(state.subscriptions.where(_validSubscription));
    final ids = _subscriptions.map((value) => value.id).toSet();
    _selected.addAll(state.selected);
    _releases.addAll(
      state.releases.where(
        (value) => ids.contains(value.subscriptionId) && _validRelease(value),
      ),
    );
    _notify();
  }

  RssSubscription? subscriptionForSubject(int bangumiId) {
    final id = _selected[bangumiId];
    return _subscriptions
        .where(
          (value) =>
              value.id == id &&
              value.bangumiId == bangumiId &&
              value.enabled &&
              value.isVerified,
        )
        .firstOrNull;
  }

  List<RssRelease> releasesForSubject(
    int bangumiId, {
    double? episodeNumber,
    String? subscriptionId,
  }) {
    final subscription = subscriptionId == null
        ? subscriptionForSubject(bangumiId)
        : _subscriptions
              .where(
                (value) =>
                    value.id == subscriptionId &&
                    value.bangumiId == bangumiId &&
                    value.enabled &&
                    value.isVerified,
              )
              .firstOrNull;
    if (subscription == null) return const [];
    final result = _releases
        .where(
          (release) =>
              release.subscriptionId == subscription.id &&
              release.bangumiId == bangumiId &&
              release.mikanId == subscription.mikanId &&
              release.subtitleGroupId == subscription.subtitleGroupId &&
              (episodeNumber == null || release.matchesEpisode(episodeNumber)),
        )
        .toList();
    result.sort(
      (a, b) => (b.publishedAt ?? DateTime(1970)).compareTo(
        a.publishedAt ?? DateTime(1970),
      ),
    );
    return List.unmodifiable(result);
  }

  Future<List<MikanShow>> searchShows(
    String keyword, {
    CancelToken? cancelToken,
  }) => _operation(
    (token) => _client.searchShows(keyword, cancelToken: token),
    cancelToken,
  );
  Future<MikanShow> getShow(int id, {CancelToken? cancelToken}) => _operation(
    (token) => _client.getShow(id, cancelToken: token),
    cancelToken,
  );
  Future<MikanShow?> resolveSubject(
    BangumiItem subject, {
    CancelToken? cancelToken,
  }) => _operation(
    (token) => _client.resolveSubject(subject, cancelToken: token),
    cancelToken,
  );
  Future<RssFeedPreview> previewFeed(Uri uri, {CancelToken? cancelToken}) =>
      _operation(
        (token) => _client.previewFeed(uri, cancelToken: token),
        cancelToken,
      );

  Future<RssSubscription> subscribe(
    BangumiItem subject,
    MikanShow show,
    MikanSubtitleGroup group, {
    CancelToken? cancelToken,
  }) => _operation((token) async {
    await initialize();
    final verified = await _client.getShow(show.id, cancelToken: token);
    if (verified.bangumiId != subject.id) {
      throw const RssException('蜜柑条目与当前 Bangumi 番剧不一致，无法绑定');
    }
    final selected = verified.groups
        .where((value) => value.id == group.id)
        .firstOrNull;
    if (selected == null) throw const RssException('所选字幕组不属于该蜜柑条目');
    final feed = await _client.previewFeed(
      selected.feedUri,
      cancelToken: token,
    );
    if (feed.mikanId != verified.id ||
        feed.subtitleGroupId != selected.id ||
        feed.bangumiId != subject.id) {
      throw const RssException('字幕组 RSS 与番剧绑定不一致');
    }
    _checkCancelled(token);
    final id = 'mikan/${subject.id}/${verified.id}/${selected.id}';
    final previous = _subscriptions
        .where((value) => value.id == id)
        .firstOrNull;
    if (previous == null && _subscriptions.length >= 128) {
      throw const RssException('RSS 订阅数量已达上限');
    }
    final subscription = RssSubscription(
      id: id,
      subject: BangumiItem.fromJson(rssSubjectToJson(subject)),
      show: verified,
      group: selected,
      createdAt: previous?.createdAt ?? _clock(),
      lastRefreshedAt: _clock(),
    );
    _revisions[id] = (_revisions[id] ?? 0) + 1;
    _subscriptions.removeWhere((value) => value.id == id);
    _subscriptions.insert(0, subscription);
    _selected[subject.id] = id;
    _replaceReleases(subscription, feed.releases);
    await _save();
    _notify();
    return subscription;
  }, cancelToken);

  Future<RssSubscription> subscribeFeed(
    BangumiItem subject,
    Uri feedUri, {
    CancelToken? cancelToken,
  }) async {
    if (!isMikanFeedUri(feedUri) ||
        feedUri.path.toLowerCase() != '/rss/bangumi') {
      throw const RssException('请选择单番剧的字幕组 RSS');
    }
    final mikanId = mikanFeedId(feedUri, 'bangumiId');
    final groupId = mikanFeedId(feedUri, 'subgroupid');
    if (mikanId == null || groupId == null) {
      throw const RssException('RSS 必须包含番剧和字幕组 ID');
    }
    final show = await getShow(mikanId, cancelToken: cancelToken);
    final group = show.groups.where((value) => value.id == groupId).firstOrNull;
    if (group == null) throw const RssException('RSS 字幕组不存在');
    return subscribe(subject, show, group, cancelToken: cancelToken);
  }

  Future<void> refresh({
    String? subscriptionId,
    CancelToken? cancelToken,
  }) => _operation((token) async {
    await initialize();
    final selected = _subscriptions
        .where(
          (value) =>
              value.enabled &&
              (subscriptionId == null || value.id == subscriptionId),
        )
        .toList();
    final updates =
        <
          ({
            RssSubscription original,
            int revision,
            RssSubscription updated,
            List<RssRelease>? releases,
          })
        >[];
    var index = 0;
    Future<void> worker() async {
      while (index < selected.length) {
        _checkCancelled(token);
        final old = selected[index++];
        if (!_subscriptions.any(
          (value) => identical(value, old) && value.enabled,
        )) {
          continue;
        }
        final revision = (_revisions[old.id] ?? 0) + 1;
        _revisions[old.id] = revision;
        try {
          final show = await _client.getShow(old.mikanId, cancelToken: token);
          if (show.bangumiId != old.bangumiId ||
              !show.groups.any((group) => group.id == old.subtitleGroupId)) {
            throw const RssException('原字幕组或番剧映射已改变，请重新绑定');
          }
          final feed = await _client.previewFeed(
            old.feedUri,
            cancelToken: token,
          );
          _checkCancelled(token);
          if (!_stillCurrent(old, revision)) continue;
          updates.add((
            original: old,
            revision: revision,
            updated: old.copyWith(lastRefreshedAt: _clock(), clearError: true),
            releases: feed.releases,
          ));
        } catch (_) {
          _checkCancelled(token);
          if (!_stillCurrent(old, revision)) continue;
          updates.add((
            original: old,
            revision: revision,
            updated: old.copyWith(lastError: 'RSS 刷新失败，请稍后重试'),
            releases: null,
          ));
        }
      }
    }

    await Future.wait([
      for (var count = 0; count < 3 && count < selected.length; count++)
        worker(),
    ]);
    _checkCancelled(token);
    for (final update in updates) {
      if (!_stillCurrent(update.original, update.revision)) continue;
      _subscriptions[_subscriptions.indexWhere(
            (value) => value.id == update.original.id,
          )] =
          update.updated;
      if (update.releases != null) {
        _replaceReleases(update.updated, update.releases!);
      }
    }
    await _save();
    _notify();
  }, cancelToken);

  Future<void> remove(String id) async {
    await initialize();
    final removed = _subscriptions.where((value) => value.id == id).firstOrNull;
    _revisions[id] = (_revisions[id] ?? 0) + 1;
    _subscriptions.removeWhere((value) => value.id == id);
    _releases.removeWhere((value) => value.subscriptionId == id);
    if (removed != null && _selected[removed.bangumiId] == id) {
      _selected.remove(removed.bangumiId);
    }
    // No selection remains; another subscribed group is never chosen silently.
    await _save();
    _notify();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await initialize();
    final index = _subscriptions.indexWhere((value) => value.id == id);
    if (index < 0) return;
    final subscription = _subscriptions[index].copyWith(enabled: enabled);
    _subscriptions[index] = subscription;
    _revisions[id] = (_revisions[id] ?? 0) + 1;
    if (enabled) _selected[subscription.bangumiId] = id;
    await _save();
    _notify();
  }

  Future<void> selectSubscription(String id) async {
    await initialize();
    final subscription = _subscriptions
        .where((value) => value.id == id && value.enabled && value.isVerified)
        .firstOrNull;
    if (subscription == null) throw const RssException('字幕组订阅不可用');
    _selected[subscription.bangumiId] = id;
    await _save();
    _notify();
  }

  bool _stillCurrent(RssSubscription old, int revision) =>
      !_disposed &&
      (_revisions[old.id] ?? 0) == revision &&
      _subscriptions.any((value) => identical(value, old) && value.enabled);
  void _replaceReleases(
    RssSubscription subscription,
    List<RssRelease> releases,
  ) {
    _releases.removeWhere((value) => value.subscriptionId == subscription.id);
    _releases.addAll(
      releases.take(500).map((value) => value.bind(subscription)),
    );
  }

  Future<void> _save() => _repository.save(
    RssStoredState(
      subscriptions: List.of(_subscriptions),
      releases: List.of(_releases),
      selected: Map.of(_selected),
    ),
  );

  Future<T> _operation<T>(
    Future<T> Function(CancelToken) body,
    CancelToken? caller,
  ) async {
    if (_disposed) throw const RssException('RSS 服务已关闭');
    _checkCancelled(caller);
    final token = CancelToken();
    final cancellation = caller?.whenCancel.asStream().listen(
      (error) => token.cancel(error),
    );
    _operations.add(token);
    _loading++;
    _lastError = null;
    _notify();
    try {
      return await body(token);
    } catch (_) {
      if (!token.isCancelled) _lastError = 'RSS 操作失败，请稍后重试';
      rethrow;
    } finally {
      await cancellation?.cancel();
      _operations.remove(token);
      _loading--;
      _notify();
    }
  }

  bool _validSubscription(RssSubscription value) =>
      value.isVerified &&
      value.subject.id > 0 &&
      value.show.id > 0 &&
      value.group.id > 0 &&
      isMikanUri(value.show.detailUri) &&
      value.show.detailUri.path == '/Home/Bangumi/${value.show.id}' &&
      isMikanFeedUri(value.feedUri) &&
      value.feedUri.path.toLowerCase() == '/rss/bangumi' &&
      mikanFeedId(value.feedUri, 'bangumiId') == value.mikanId &&
      mikanFeedId(value.feedUri, 'subgroupid') == value.subtitleGroupId;
  bool _validRelease(RssRelease value) =>
      isMikanEpisodeUri(value.detailUri) &&
      (value.torrentUri != null || value.magnetUri != null) &&
      (value.torrentUri == null || isMikanTorrentUri(value.torrentUri!)) &&
      (value.magnetUri == null || validRssMagnet(value.magnetUri));
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _autoRefresh?.dispose();
    for (final token in _operations) {
      token.cancel('RSS 服务已关闭');
    }
    _client.dispose();
    super.dispose();
  }
}

void _checkCancelled(CancelToken? token) {
  if (token?.isCancelled ?? false) throw token!.cancelError!;
}
