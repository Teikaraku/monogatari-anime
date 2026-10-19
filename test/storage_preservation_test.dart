import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/hive_registrar.g.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/rss/rss_subscription_repository.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _FutureSchema {
  const _FutureSchema();
}

class _FutureSchemaAdapter extends TypeAdapter<_FutureSchema> {
  @override
  int get typeId => 223;
  @override
  _FutureSchema read(BinaryReader reader) {
    reader.readString();
    return const _FutureSchema();
  }

  @override
  void write(BinaryWriter writer, _FutureSchema value) =>
      writer.writeString('kept');
}

void main() {
  late Directory directory;
  late PathProviderPlatform paths;
  setUp(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp(
      'monogatari_storage_preservation_',
    );
    paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    Hive.init('${directory.path}/hive');
    Hive.resetAdapters();
  });
  tearDown(() async {
    await Hive.close();
    PathProviderPlatform.instance = paths;
    // Hive asynchronously releases the failed box's file handles.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      directory.absolute.path.startsWith(Directory.systemTemp.absolute.path),
      true,
    );
    expect(
      directory.uri.pathSegments.where((p) => p.isNotEmpty).last,
      startsWith('monogatari_storage_preservation_'),
    );
    await directory.delete(recursive: true);
  });

  test(
    'an unsupported schema fails initialization without deleting the original box',
    () async {
      Hive.registerAdapter(_FutureSchemaAdapter());
      final box = await Hive.openBox<dynamic>('histories');
      await box.put('saved-history', const _FutureSchema());
      await box.close();
      final file = File('${directory.path}/hive/histories.hive');
      final before = await file.readAsBytes();
      Hive.resetAdapters();
      await expectLater(GStorage.init(), throwsA(isA<HiveError>()));
      expect(await file.readAsBytes(), before);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      Hive.registerAdapter(_FutureSchemaAdapter());
      final recovered = await Hive.openBox<dynamic>(
        'histories',
        crashRecovery: false,
      );
      expect(recovered.get('saved-history'), isA<_FutureSchema>());
    },
  );

  test(
    'checksum failure does not truncate any previously stored library data',
    () async {
      Hive.registerAdapters();
      final box = await Hive.openBox<BangumiItem>('favorites');
      await box.put(
        'saved-item',
        BangumiItem.fromJson({'id': 1, 'name': 'Test', 'rating': {}}),
      );
      await box.close();
      final file = File('${directory.path}/hive/favorites.hive');
      await file.writeAsBytes([1, 2, 3], mode: FileMode.append, flush: true);
      final before = await file.readAsBytes();
      Hive.resetAdapters();
      await expectLater(GStorage.init(), throwsA(isA<HiveError>()));
      expect(await file.readAsBytes(), before);
    },
  );

  test(
    'RSS opening also preserves a damaged file and refuses subsequent saves',
    () async {
      final box = await Hive.openBox<dynamic>('rss_subscriptions');
      await box.put('state', {
        'version': 1,
        'subscriptions': [],
        'releases': [],
      });
      await box.close();
      final file = File('${directory.path}/hive/rss_subscriptions.hive');
      await file.writeAsBytes([1, 2, 3], mode: FileMode.append, flush: true);
      final before = await file.readAsBytes();
      final repo = HiveRssSubscriptionRepository();
      await expectLater(repo.load(), throwsA(isA<HiveError>()));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await expectLater(
        repo.save(const RssStoredState()),
        throwsA(isA<HiveError>()),
      );
      expect(await file.readAsBytes(), before);
    },
  );
}
