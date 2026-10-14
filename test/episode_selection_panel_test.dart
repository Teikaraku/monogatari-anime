import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/video/episode_selection_panel.dart';

void main() {
  late List<Road> roads;

  setUp(() {
    roads = [
      Road(
        name: '第一缓存列表',
        data: ['first-1', 'first-2'],
        identifier: ['第一组第 1 集', '第一组第 2 集'],
      ),
      Road(
        name: '第二缓存列表',
        data: ['second-1', 'second-2'],
        identifier: ['第二组第 1 集', '第二组第 2 集'],
      ),
    ];
  });

  Future<void> mount(
    WidgetTester tester, {
    int selectedRoad = 0,
    bool isOffline = false,
    void Function(int, int)? onSelected,
    List<Road>? episodeRoads,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EpisodeSelectionPanel(
            title: '测试番剧',
            roads: episodeRoads ?? roads,
            selectedRoad: selectedRoad,
            selectedEpisode: 1,
            downloads: const {},
            isOffline: isOffline,
            disableAnimations: true,
            onEpisodeSelected: onSelected ?? (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('online episodes remain selectable without a source menu', (
    tester,
  ) async {
    final selected = <(int, int)>[];
    await mount(
      tester,
      selectedRoad: 1,
      onSelected: (episode, road) => selected.add((episode, road)),
    );

    expect(find.text('自动选择可用播放资源'), findsNothing);
    expect(find.byType(MenuAnchor), findsNothing);
    expect(find.text('第一缓存列表'), findsNothing);
    expect(find.text('第二缓存列表'), findsNothing);
    expect(find.text('第二组第 2 集'), findsOneWidget);

    await tester.tap(find.text('第二组第 2 集'));
    expect(selected, [(2, 1)]);
  });

  testWidgets('the whole episode row is tappable, not just its text', (
    tester,
  ) async {
    final selected = <(int, int)>[];
    await mount(
      tester,
      onSelected: (episode, road) => selected.add((episode, road)),
    );

    final row = find.ancestor(
      of: find.text('第一组第 2 集'),
      matching: find.byType(InkWell),
    );
    expect(tester.getSize(row).width,
        tester.getSize(find.byType(EpisodeSelectionPanel)).width - 32);
    await tester.tapAt(tester.getTopRight(row) + const Offset(-8, 25));
    expect(selected, [(2, 0)]);
  });

  testWidgets('online episode list follows an automatic source change', (
    tester,
  ) async {
    final selected = <(int, int)>[];
    await mount(tester);
    expect(find.text('第一组第 1 集'), findsOneWidget);

    await mount(
      tester,
      selectedRoad: 1,
      onSelected: (episode, road) => selected.add((episode, road)),
    );
    expect(find.text('第一组第 1 集'), findsNothing);
    expect(find.text('第二组第 1 集'), findsOneWidget);
    await tester.tap(find.text('第二组第 1 集'));
    expect(selected, [(1, 1)]);
  });

  testWidgets('offline playback can still switch between cached lists', (
    tester,
  ) async {
    final selected = <(int, int)>[];
    await mount(
      tester,
      isOffline: true,
      onSelected: (episode, road) => selected.add((episode, road)),
    );

    expect(find.text('自动选择可用播放资源'), findsNothing);
    await tester.tap(find.text('第一缓存列表'));
    await tester.pumpAndSettle();
    expect(find.text('选择缓存列表'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('road-option-1')));
    await tester.pumpAndSettle();
    expect(find.text('第二组第 2 集'), findsOneWidget);
    await tester.tap(find.text('第二组第 2 集'));
    expect(selected, [(2, 1)]);
  });

  testWidgets('an empty online list explains that no episode is available', (
    tester,
  ) async {
    await mount(tester, episodeRoads: []);
    expect(find.text('暂无可播放剧集'), findsOneWidget);
    expect(find.byType(MenuAnchor), findsNothing);
  });
}
