import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';

import 'mikan_rss_client.dart';
import 'rss_subscription_repository.dart';
import 'rss_refresh_coordinator.dart';
import 'rss_sync.dart';

export 'rss_models.dart';
export 'rss_subscription_repository.dart';
export 'rss_sync.dart';

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
  final Map<int, DateTime> _viewed = {};
  final Map<String, RssSyncStamp> _stamps = {};
  final Map<int, RssSyncStamp> _selectionStamps = {};
  final _localEdits = StreamController<void>.broadcast();
  final Map<String, int> _revisions = {};

  /// When each subscription's show mapping was last confirmed this session.
  /// The mapping rarely changes, so refreshes re-read the show page daily.
  final Map<String, DateTime> _verifiedAt = {};
  static const _verifyEvery = Duration(hours: 24);
  final Set<CancelToken> _operations = {};
  int _loading = 0;
  bool _disposed = false;
  String? _lastError;
  RssRefreshCoordinator? _autoRefresh;

  List<RssSubscription> get subscriptions => List.unmodifiable(_subscriptions);

  /// Changes the user made on this device, for sync.
  Stream<void> get localEdits => _localEdits.stream;
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
    _viewed.addAll(state.viewed);
    _stamps.addAll(state.stamps);
    _selectionStamps.addAll(state.selectionStamps);
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

  /// Releases published after this are new for the show: since its page was
  /// last opened, or since the first subscription if it never was.
  DateTime? newSince(int bangumiId) {
    final viewed = _viewed[bangumiId];
    if (viewed != null) return viewed;
    final created = _subscriptions
        .where((value) => value.bangumiId == bangumiId)
        .map((value) => value.createdAt);
    return created.isEmpty
        ? null
        : created.reduce((a, b) => a.isBefore(b) ? a : b);
  }

  int newReleaseCount(int bangumiId) {
    final since = newSince(bangumiId);
    if (since == null) return 0;
    return releasesForSubject(
      bangumiId,
    ).where((release) => release.publishedAt?.isAfter(since) ?? false).length;
  }

  Future<void> markViewed(int bangumiId) async {
    await initialize();
    _viewed[bangumiId] = _clock();
    await _save();
    _notify();
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
    _verifiedAt[id] = _clock();
    _subscriptions.removeWhere((value) => value.id == id);
    _subscriptions.insert(0, subscription);
    _selected[subject.id] = id;
    _stamp(id);
    _stampSelection(subject.id);
    _replaceReleases(subscription, feed.releases);
    await _save();
    _notify();
    _edited();
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

  Future<void> refresh({String? subscriptionId, CancelToken? cancelToken}) =>
      _operation(
        (token) async {
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
                final verified = _verifiedAt[old.id];
                final verify =
                    verified == null ||
                    _clock().difference(verified) >= _verifyEvery;
                if (verify) {
                  final show = await _client.getShow(
                    old.mikanId,
                    cancelToken: token,
                  );
                  if (show.bangumiId != old.bangumiId ||
                      !show.groups.any(
                        (group) => group.id == old.subtitleGroupId,
                      )) {
                    throw const RssException('番剧或字幕组在蜜柑上已变化，请删除后重新订阅');
                  }
                }
                final feed = await _client.previewFeed(
                  old.feedUri,
                  cancelToken: token,
                  resolveShow: false,
                );
                _checkCancelled(token);
                if (verify) _verifiedAt[old.id] = _clock();
                if (!_stillCurrent(old, revision)) continue;
                updates.add((
                  original: old,
                  revision: revision,
                  updated: old.copyWith(
                    lastRefreshedAt: _clock(),
                    clearError: true,
                  ),
                  releases: feed.releases,
                ));
              } catch (error) {
                _checkCancelled(token);
                if (!_stillCurrent(old, revision)) continue;
                updates.add((
                  original: old,
                  revision: revision,
                  // Client errors are already safe to show and say what to do.
                  updated: old.copyWith(
                    lastError: error is RssException
                        ? error.message
                        : 'RSS 刷新失败，请稍后重试',
                  ),
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
        },
        cancelToken,
        reportError: true,
      );

  Future<void> remove(String id) async {
    await initialize();
    final removed = _subscriptions.where((value) => value.id == id).firstOrNull;
    _revisions[id] = (_revisions[id] ?? 0) + 1;
    _subscriptions.removeWhere((value) => value.id == id);
    _releases.removeWhere((value) => value.subscriptionId == id);
    if (removed != null && _selected[removed.bangumiId] == id) {
      _selected.remove(removed.bangumiId);
    }
    if (removed != null) _stamp(id, deleted: true);
    // No selection remains; another subscribed group is never chosen silently.
    await _save();
    _notify();
    if (removed != null) _edited();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await initialize();
    final index = _subscriptions.indexWhere((value) => value.id == id);
    if (index < 0) return;
    final subscription = _subscriptions[index].copyWith(enabled: enabled);
    _subscriptions[index] = subscription;
    _revisions[id] = (_revisions[id] ?? 0) + 1;
    // Resuming a group never replaces the one picked for playback.
    if (enabled && subscriptionForSubject(subscription.bangumiId) == null) {
      _selected[subscription.bangumiId] = id;
      _stampSelection(subscription.bangumiId);
    }
    _stamp(id);
    await _save();
    _notify();
    _edited();
  }

  Future<void> selectSubscription(String id) async {
    await initialize();
    final subscription = _subscriptions
        .where((value) => value.id == id && value.enabled && value.isVerified)
        .firstOrNull;
    if (subscription == null) throw const RssException('字幕组订阅不可用');
    _selected[subscription.bangumiId] = id;
    _stampSelection(subscription.bangumiId);
    await _save();
    _notify();
    _edited();
  }

  void _stamp(String id, {bool deleted = false}) => _stamps[id] = (
    at: _clock().millisecondsSinceEpoch,
    device: null,
    deleted: deleted,
  );

  void _stampSelection(int bangumiId) => _selectionStamps[bangumiId] = (
    at: _clock().millisecondsSinceEpoch,
    device: null,
    deleted: false,
  );

  void _edited() {
    if (!_localEdits.isClosed) _localEdits.add(null);
  }

  /// This device's subscriptions and picks as [deviceId] publishes them.
  RssSyncState exportSync(String deviceId) {
    final present = {for (final value in _subscriptions) value.id};
    return RssSyncState(
      entries: [
        for (final value in _subscriptions)
          RssSyncEntry(
            id: value.id,
            updatedAt:
                _stamps[value.id]?.at ?? value.createdAt.millisecondsSinceEpoch,
            deviceId: _stamps[value.id]?.device ?? deviceId,
            subscription: _syncJson(value),
          ),
        for (final MapEntry(:key, :value) in _stamps.entries)
          if (value.deleted && !present.contains(key))
            RssSyncEntry(
              id: key,
              updatedAt: value.at,
              deviceId: value.device ?? deviceId,
            ),
      ],
      selections: [
        for (final MapEntry(:key, :value) in _selected.entries)
          RssSyncSelection(
            bangumiId: key,
            subscriptionId: value,
            updatedAt: _selectionStamps[key]?.at ?? 0,
            deviceId: _selectionStamps[key]?.device ?? deviceId,
          ),
      ],
    );
  }

  static Map<String, dynamic> _syncJson(RssSubscription value) => value.toJson()
    ..remove('lastRefreshedAt')
    ..remove('lastError');

  /// Applies whatever [remote] holds that is newer than this device's copy and
  /// returns the merged state to publish. New subscriptions fetch their feeds.
  Future<RssSyncState> mergeSyncState(
    RssSyncState remote,
    String deviceId,
  ) async {
    await initialize();
    final local = exportSync(deviceId);
    final merged = local.merge(remote);
    final added = <String>[];
    var changed = false;
    for (final entry in merged.entries.values) {
      final mine = local.entries[entry.id];
      if (mine != null && mine.sameVersion(entry)) continue;
      final index = _subscriptions.indexWhere((value) => value.id == entry.id);
      if (entry.deleted) {
        if (index >= 0) {
          final removed = _subscriptions.removeAt(index);
          _releases.removeWhere((value) => value.subscriptionId == entry.id);
          _revisions[entry.id] = (_revisions[entry.id] ?? 0) + 1;
          if (_selected[removed.bangumiId] == entry.id) {
            _selected.remove(removed.bangumiId);
          }
        }
      } else {
        final RssSubscription incoming;
        try {
          incoming = RssSubscription.fromJson(entry.subscription!);
        } catch (_) {
          continue;
        }
        if (incoming.id != entry.id || !_validSubscription(incoming)) continue;
        if (index >= 0) {
          final old = _subscriptions[index];
          _subscriptions[index] = RssSubscription(
            id: incoming.id,
            subject: incoming.subject,
            show: incoming.show,
            group: incoming.group,
            createdAt: incoming.createdAt,
            enabled: incoming.enabled,
            lastRefreshedAt: old.lastRefreshedAt,
            lastError: old.lastError,
          );
          _revisions[entry.id] = (_revisions[entry.id] ?? 0) + 1;
        } else {
          if (_subscriptions.length >= 128) continue;
          _subscriptions.insert(0, incoming);
          added.add(incoming.id);
        }
      }
      _stamps[entry.id] = (
        at: entry.updatedAt,
        device: entry.deviceId == deviceId ? null : entry.deviceId,
        deleted: entry.deleted,
      );
      changed = true;
    }
    for (final selection in merged.selections.values) {
      final mine = local.selections[selection.bangumiId];
      if (mine != null && mine.sameVersion(selection)) continue;
      if (!_subscriptions.any(
        (value) =>
            value.id == selection.subscriptionId &&
            value.bangumiId == selection.bangumiId,
      )) {
        continue;
      }
      _selected[selection.bangumiId] = selection.subscriptionId;
      _selectionStamps[selection.bangumiId] = (
        at: selection.updatedAt,
        device: selection.deviceId == deviceId ? null : selection.deviceId,
        deleted: false,
      );
      changed = true;
    }
    if (changed) {
      await _save();
      _notify();
    }
    for (final id in added) {
      unawaited(refresh(subscriptionId: id).catchError((Object _) {}));
    }
    return merged;
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
      viewed: Map.of(_viewed),
      stamps: Map.of(_stamps),
      selectionStamps: Map.of(_selectionStamps),
    ),
  );

  /// Pages show their own request failures; only a background refresh that
  /// fails as a whole is reported through [lastError].
  Future<T> _operation<T>(
    Future<T> Function(CancelToken) body,
    CancelToken? caller, {
    bool reportError = false,
  }) async {
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
      if (reportError && !token.isCancelled) _lastError = 'RSS 刷新失败，请稍后重试';
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
    unawaited(_localEdits.close());
    super.dispose();
  }
}

void _checkCancelled(CancelToken? token) {
  if (token?.isCancelled ?? false) throw token!.cancelError!;
}
