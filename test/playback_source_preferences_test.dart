import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/player/playback_source_preferences.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  test(
    'missing or damaged stored data has no subject override and never writes',
    () {
      var writes = 0;
      for (final value in [
        null,
        'rss',
        42,
        ['api'],
        <dynamic, dynamic>{},
      ]) {
        final preferences = PlaybackSourcePreferences(
          read: () => value,
          write: (_) async {
            writes++;
          },
        );
        expect(preferences.forSubject(42), isNull);
      }
      expect(writes, 0);
    },
  );

  test(
    'legacy numeric keys are read while corrupt IDs and choices are ignored',
    () {
      final preferences = PlaybackSourcePreferences(
        read: () => {
          42: 'rss',
          '7': 'api',
          '003': 'rss',
          'bad': 'rss',
          '-1': 'api',
          0: 'rss',
          1.5: 'api',
          '4': true,
          '5': 'other',
          '6': ['rss'],
        },
      );
      expect(preferences.forSubject(42), 'rss');
      expect(preferences.forSubject(7), 'api');
      expect(preferences.forSubject(3), 'rss');
      for (final id in [-1, 0, 1, 4, 5, 6, 99]) {
        expect(preferences.forSubject(id), isNull);
      }
    },
  );

  test(
    'a user choice is immediately readable while its disk write is pending',
    () async {
      final pending = Completer<void>();
      final preferences = PlaybackSourcePreferences(
        read: () => null,
        write: (_) => pending.future,
      );
      final saving = preferences.remember(42, 'rss');
      expect(preferences.forSubject(42), 'rss');
      expect(preferences.forSubject(7), isNull);
      pending.complete();
      await saving;
    },
  );

  test('rapid choices write in order without losing other subjects', () async {
    final pending = <Completer<void>>[];
    final snapshots = <Map<dynamic, dynamic>>[];
    Object? stored = {99: 'api'};
    final preferences = PlaybackSourcePreferences(
      read: () => stored,
      write: (snapshot) async {
        snapshots.add(Map.of(snapshot));
        final next = Completer<void>();
        pending.add(next);
        await next.future;
        stored = Map.of(snapshot);
      },
    );
    final first = preferences.remember(42, 'rss');
    final second = preferences.remember(7, 'rss');
    final third = preferences.remember(42, 'api');
    expect(preferences.forSubject(42), 'api');
    expect(preferences.forSubject(7), 'rss');
    await Future<void>.delayed(Duration.zero);
    expect(pending, hasLength(1));
    pending[0].complete();
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(pending, hasLength(2));
    pending[1].complete();
    await second;
    await Future<void>.delayed(Duration.zero);
    expect(pending, hasLength(3));
    pending[2].complete();
    await third;
    expect(snapshots, [
      {'99': 'api', '42': 'rss'},
      {'99': 'api', '42': 'rss', '7': 'rss'},
      {'99': 'api', '42': 'api', '7': 'rss'},
    ]);
  });

  test(
    'completed storage restores choices in a new application service',
    () async {
      Object? stored;
      final first = PlaybackSourcePreferences(
        read: () => stored,
        write: (snapshot) async {
          stored = Map.of(snapshot);
        },
      );
      await first.remember(42, 'rss');
      await first.remember(7, 'api');
      final restored = PlaybackSourcePreferences(read: () => stored);
      expect(restored.forSubject(42), 'rss');
      expect(restored.forSubject(7), 'api');
    },
  );

  test(
    'failed writes are reported and do not poison later persistence',
    () async {
      var fail = true;
      Object? stored;
      final preferences = PlaybackSourcePreferences(
        read: () => stored,
        write: (snapshot) async {
          if (fail) throw StateError('disk is temporarily unavailable');
          stored = Map.of(snapshot);
        },
      );
      await expectLater(preferences.remember(42, 'rss'), throwsStateError);
      expect(preferences.forSubject(42), isNull);
      fail = false;
      await preferences.remember(7, 'api');
      expect(
        PlaybackSourcePreferences(read: () => stored).forSubject(42),
        isNull,
      );
      expect(stored, {'7': 'api'});
      await preferences.remember(42, 'rss');
      expect(preferences.forSubject(42), 'rss');
    },
  );

  test(
    'invalid writes and repeated lookups never replace an explicit choice',
    () async {
      var writes = 0;
      final preferences = PlaybackSourcePreferences(
        read: () => {'42': 'rss'},
        write: (_) async {
          writes++;
        },
      );
      await preferences.remember(0, 'api');
      await preferences.remember(-1, 'rss');
      await preferences.remember(42, 'automatic');
      expect(preferences.forSubject(42), 'rss');
      expect(preferences.forSubject(42), 'rss');
      expect(writes, 0);
    },
  );

  test(
    'default settings backing roundtrips a Hive map and recovers a wrong stored type',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final directory = await Directory.systemTemp.createTemp(
        'monogatari_source_preferences_',
      );
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(directory.path);
      Hive.init(directory.path);
      try {
        await GStorage.init();
        final box = Hive.box<dynamic>('setting');
        await box.put(SettingsKeys.subjectPlaybackSources.name, ['damaged']);
        final preferences = PlaybackSourcePreferences();
        expect(preferences.forSubject(42), isNull);
        await preferences.remember(42, 'rss');
        await preferences.remember(7, 'api');
        await box.flush();
        expect(box.get(SettingsKeys.subjectPlaybackSources.name), {
          '42': 'rss',
          '7': 'api',
        });
        final restored = PlaybackSourcePreferences();
        expect(restored.forSubject(42), 'rss');
        expect(restored.forSubject(7), 'api');
        await GStorage.resetPlayerSettings();
        expect(preferences.forSubject(42), isNull);
        expect(restored.forSubject(7), isNull);
        await preferences.remember(42, 'api');
        expect(box.get(SettingsKeys.subjectPlaybackSources.name), {
          '42': 'api',
        });
        expect(preferences.forSubject(7), isNull);
      } finally {
        await Hive.close();
        PathProviderPlatform.instance = oldPaths;
        expect(directory.parent.path, Directory.systemTemp.path);
        expect(
          directory.path.split(Platform.pathSeparator).last,
          startsWith('monogatari_source_preferences_'),
        );
        await directory.delete(recursive: true);
      }
    },
  );
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}
