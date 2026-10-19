import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/info/info_catalog_prefetch.dart';

void main() {
  test('default detail route owns revisions without a provider warmup', () {
    final owner = InfoCatalogPrefetch();
    final subject = _subject(42);
    final revision = owner.beginSubject(subject.id);
    owner.afterDetailsApplied(revision, subject);
    expect(owner.isCurrent(revision, 42), isTrue);
    owner.dispose();
    expect(owner.isCurrent(revision, 42), isFalse);
  });
  test('sparse detail input does not warm a partial matching key', () {
    final calls = <BangumiItem>[];
    final owner = InfoCatalogPrefetch((subject, _) async => calls.add(subject));
    addTearDown(owner.dispose);

    owner.beginSubject(42);
    // Opening the route alone is insufficient: a failed detail request must
    // leave normal playback lookup available without caching sparse names.
    expect(calls, isEmpty);
  });

  test(
    'fully applied names and aliases warm without awaiting the catalog',
    () async {
      final pending = Completer<void>();
      final calls = <BangumiItem>[];
      final owner = InfoCatalogPrefetch((subject, _) {
        calls.add(subject);
        return pending.future;
      });
      addTearDown(owner.dispose);
      final item = _subject(42, name: 'Sparse title');
      final revision = owner.beginSubject(item.id);

      item.name = 'Official Japanese title';
      item.nameCn = '官方中文标题';
      item.alias = ['完整别名'];
      owner.afterDetailsApplied(revision, item);

      expect(calls, hasLength(1));
      expect(pending.isCompleted, isFalse);
      expect(calls.single.name, item.name);
      expect(calls.single.nameCn, item.nameCn);
      expect(calls.single.alias, item.alias);
      pending.complete();
      await pending.future;
    },
  );

  test(
    'warmup freezes the resolved matching metadata while requests are pending',
    () async {
      final pending = Completer<void>();
      late BangumiItem snapshot;
      final owner = InfoCatalogPrefetch((subject, _) {
        snapshot = subject;
        return pending.future;
      });
      addTearDown(owner.dispose);
      final item = _subject(
        42,
        name: 'Resolved title',
        aliases: ['Original alias'],
      );
      owner.afterDetailsApplied(owner.beginSubject(item.id), item);

      item.name = 'Later title';
      item.alias.add('Later alias');
      expect(snapshot.name, 'Resolved title');
      expect(snapshot.alias, ['Original alias']);
      pending.complete();
      await pending.future;
    },
  );

  test(
    'changing the subject cancels its warmup and rejects late old details',
    () async {
      final pending = Completer<void>();
      final calls = <(BangumiItem, CancelToken)>[];
      final owner = InfoCatalogPrefetch((subject, cancellation) {
        calls.add((subject, cancellation));
        return pending.future;
      });
      addTearDown(owner.dispose);
      final first = _subject(42);
      final firstRevision = owner.beginSubject(first.id);
      owner.afterDetailsApplied(firstRevision, first);

      final second = _subject(43);
      final secondRevision = owner.beginSubject(second.id);
      expect(calls.single.$2.isCancelled, isTrue);
      owner.afterDetailsApplied(firstRevision, first);
      expect(calls, hasLength(1));
      owner.afterDetailsApplied(secondRevision, second);
      expect(calls, hasLength(2));
      expect(calls.last.$1.id, 43);
      expect(calls.last.$2.isCancelled, isFalse);
      expect(calls.last.$2, isNot(same(calls.first.$2)));
      pending.complete();
      await pending.future;
    },
  );

  test('replacement of the same subject rejects an older request revision', () {
    final calls = <BangumiItem>[];
    final owner = InfoCatalogPrefetch((subject, _) async => calls.add(subject));
    addTearDown(owner.dispose);
    final item = _subject(42);
    final first = owner.beginSubject(item.id);
    final replacement = owner.beginSubject(item.id);

    owner.afterDetailsApplied(first, item);
    expect(calls, isEmpty);
    owner.afterDetailsApplied(replacement, item);
    expect(calls, hasLength(1));
  });

  test(
    'dispose cancels the route warmup and cannot start late work',
    () async {
      final pending = Completer<void>();
      final calls = <CancelToken>[];
      final owner = InfoCatalogPrefetch((_, cancellation) {
        calls.add(cancellation);
        return pending.future;
      });
      final item = _subject(42);
      final revision = owner.beginSubject(item.id);
      owner.afterDetailsApplied(revision, item);

      owner.dispose();
      expect(calls.single.isCancelled, isTrue);
      expect(owner.isCurrent(revision, item.id), isFalse);
      owner.afterDetailsApplied(revision, item);
      expect(calls, hasLength(1));
      pending.complete();
      await pending.future;
    },
  );

  test('dispose before details finish prevents any warmup', () {
    final calls = <BangumiItem>[];
    final owner = InfoCatalogPrefetch((subject, _) async => calls.add(subject));
    final item = _subject(42);
    final revision = owner.beginSubject(item.id);

    owner.dispose();
    owner.afterDetailsApplied(revision, item);
    expect(calls, isEmpty);
  });

  test(
    'synchronous and asynchronous warmup failures are optional and consumed',
    () async {
      for (final warmup in <InfoCatalogWarmup>[
        (_, _) => throw StateError('service unavailable'),
        (_, _) async => throw StateError('network unavailable'),
      ]) {
        final owner = InfoCatalogPrefetch(warmup);
        final item = _subject(42);
        final revision = owner.beginSubject(item.id);
        expect(
          () => owner.afterDetailsApplied(revision, item),
          returnsNormally,
        );
        await Future<void>.delayed(Duration.zero);
        expect(owner.isCurrent(revision, item.id), isTrue);
        owner.dispose();
      }
    },
  );
}

BangumiItem _subject(
  int id, {
  String name = 'Full title',
  List<String> aliases = const [],
}) => BangumiItem(
  id: id,
  type: 2,
  name: name,
  nameCn: name,
  summary: '',
  airDate: '2024-01-01',
  airWeekday: 1,
  rank: 0,
  images: {},
  tags: [],
  alias: List.of(aliases),
  ratingScore: 0,
  votes: 0,
  votesCount: [],
  info: '',
);
