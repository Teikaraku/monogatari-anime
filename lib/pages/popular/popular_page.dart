import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/widget/bangumi_mirror_error_widget.dart';
import 'package:kazumi/bean/widget/mono_chip.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/theme.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/popular/popular_controller.dart';
import 'package:kazumi/bean/card/bangumi_card.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/platform/desktop_window_config.dart';
import 'package:kazumi/bean/appbar/drag_to_move_bar.dart' as dtb;
import 'package:kazumi/utils/device.dart';

class PopularPage extends StatefulWidget {
  const PopularPage({
    super.key,
    required this.controller,
  });

  final PopularController controller;

  @override
  State<PopularPage> createState() => _PopularPageState();
}

class _PopularPageState extends State<PopularPage> {
  late final ScrollController scrollController;
  PopularController get popularController => widget.controller;

  @override
  void initState() {
    super.initState();
    scrollController = ScrollController(
      initialScrollOffset: popularController.scrollOffset,
    );
    scrollController.addListener(scrollListener);
    if (popularController.trendList.isEmpty) {
      popularController.queryBangumiByTrend();
    }
  }

  @override
  void dispose() {
    scrollController.removeListener(scrollListener);
    scrollController.dispose();
    super.dispose();
  }

  void scrollListener() {
    popularController.scrollOffset = scrollController.offset;
    if (scrollController.position.pixels >=
            scrollController.position.maxScrollExtent - 200 &&
        !popularController.isLoadingMore) {
      KazumiLogger()
          .i('PopularPageController: Fetching next recommendation batch');
      if (popularController.currentTag != '') {
        popularController.queryBangumiByTag();
      } else {
        popularController.queryBangumiByTrend();
      }
    }
  }

  /// Width of this page, which is narrower than the window beside the sidebar.
  double _width = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(builder: (context, constraints) {
        _width = constraints.maxWidth;
        return _buildScrollView();
      }),
      floatingActionButton: FloatingActionButton.small(
        tooltip: '回到顶部',
        onPressed: () => scrollController.animateTo(0,
            duration: const Duration(milliseconds: 350), curve: Curves.easeOut),
        child: const Icon(Icons.arrow_upward_rounded),
      ),
    );
  }

  Widget _buildScrollView() {
    return CustomScrollView(
        controller: scrollController,
        slivers: [
          buildSliverAppBar(),
          SliverToBoxAdapter(child: _buildTagBar()),
          SliverToBoxAdapter(
            child: Observer(
              builder: (_) => AnimatedOpacity(
                opacity: popularController.isLoadingMore ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: popularController.isLoadingMore
                      ? const ClipRRect(
                          borderRadius: BorderRadius.all(Radius.circular(2)),
                          child: LinearProgressIndicator(minHeight: 3),
                        )
                      : const SizedBox(height: 3),
                ),
              ),
            ),
          ),
          SliverPadding(
              padding: EdgeInsets.zero,
              sliver: Observer(builder: (_) {
                if (popularController.isTimeOut) {
                  return SliverToBoxAdapter(
                    child: SizedBox(
                      height: 400,
                      child: BangumiMirrorErrorWidget(
                        onRetry: () {
                          if (popularController.trendList.isEmpty) {
                            popularController.queryBangumiByTrend();
                          } else {
                            popularController.queryBangumiByTag();
                          }
                        },
                        onSettingsReturned: () {
                          if (mounted) {
                            setState(() {});
                          }
                        },
                      ),
                    ),
                  );
                }
                return contentGrid(
                  (popularController.currentTag == '')
                      ? popularController.trendList
                      : popularController.bangumiList,
                );
              })),
        ],
    );
  }

  /// Same column rhythm as the Monogatari bookstore: three covers on phones,
  /// more as the window widens, inside a centred column on large screens.
  Widget contentGrid(List<BangumiItem> bangumiList) {
    final width = _width;
    final content = _contentWidth(width);
    final inset = (width - content) / 2;
    final crossCount = width < LayoutBreakpoint.compact['width']!
        ? 3
        : (content / 150).floor().clamp(4, 8);
    const spacing = 12.0;
    final cardWidth = (content - spacing * (crossCount - 1)) / crossCount;
    final showRating = GStorage.getSetting(SettingsKeys.showRating);
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(inset, 12, inset, 96),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          mainAxisSpacing: 16,
          crossAxisSpacing: spacing,
          crossAxisCount: crossCount,
          mainAxisExtent: cardWidth / bangumiCoverAspectRatio +
              BangumiCardV.textHeightFor(MediaQuery.textScalerOf(context),
                  showRating: showRating),
        ),
        delegate: SliverChildBuilderDelegate(
          (BuildContext context, int index) {
            return bangumiList.isNotEmpty
                ? BangumiCardV(
                    bangumiItem: bangumiList[index],
                    showRating: showRating,
                  )
                : const _CardPlaceholder();
          },
          childCount: bangumiList.isNotEmpty ? bangumiList.length : 12,
        ),
      ),
    );
  }

  double _contentWidth(double width) =>
      (width - 40).clamp(0.0, 1280.0).toDouble();

  String get _currentTitle => popularController.currentTag == ''
      ? '热门番组'
      : popularController.currentTag;

  /// Large title that shrinks into the toolbar as the grid scrolls, the
  /// Monogatari page title with a collapsing behaviour.
  Widget buildSliverAppBar() {
    final theme = Theme.of(context);
    const toolbar = SysAppBar.actionRowHeight;
    const expanded = toolbar + SysAppBar.largeTitleHeight;
    final topPadding = MediaQuery.paddingOf(context).top;
    final width = _width;
    final inset = (width - _contentWidth(width)) / 2;
    return SliverAppBar(
      pinned: true,
      elevation: 0,
      toolbarHeight: toolbar,
      expandedHeight: expanded,
      titleSpacing: 0,
      centerTitle: false,
      backgroundColor: theme.scaffoldBackgroundColor,
      actions: buildActions(),
      title: null,
      flexibleSpace: dtb.DragToMoveArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final t = (1 -
                    ((constraints.maxHeight - topPadding - toolbar) /
                        (expanded - toolbar)))
                .clamp(0.0, 1.0);
            final fontSize = lerpDouble(34, 19, t)!;
            return Stack(
              children: [
                Positioned(
                  left: inset,
                  right: 120,
                  bottom: lerpDouble(10, 12, t),
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Observer(
                      builder: (_) => Text(
                        _currentTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineLarge?.copyWith(
                          fontSize: fontSize,
                          height: 1.2,
                          letterSpacing: 0.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
                // A hairline appears once the content slides under the bar.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Opacity(
                    opacity: t,
                    child: Container(
                      height: 0.5,
                      color: MonoPalette.of(context).hairline,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Tags as chips, like the ranking periods of the Monogatari bookstore.
  Widget _buildTagBar() {
    final width = _width;
    final inset = (width - _contentWidth(width)) / 2;
    return SizedBox(
      height: 44,
      child: Observer(
        builder: (_) => ListView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: inset),
          children: [
            for (final tag in ['', ...bangumiOfficialGenres])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: MonoChip(
                  label: tag.isEmpty ? '热门' : tag,
                  selected: tag == popularController.currentTag,
                  onTap: () => _selectTag(tag),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> buildActions() {
    return <Widget>[
      if (MediaQuery.of(context).orientation == Orientation.portrait)
        IconButton(
          tooltip: '搜索',
          onPressed: () => context.pushNamed('/search/'),
          icon: const Icon(Icons.search_rounded),
        ),
      IconButton(
        tooltip: '历史记录',
        onPressed: () => context.pushNamed('/settings/history/'),
        icon: const Icon(Icons.history_rounded),
      ),
      if (isDesktop() && !DesktopWindowConfig.showWindowButton)
        IconButton(
          tooltip: '退出',
          onPressed: () => windowManager.close(),
          icon: const Icon(Icons.close_rounded),
        ),
      const SizedBox(width: 6),
    ];
  }

  Future<void> _selectTag(String selected) async {
    if (!mounted || selected == popularController.currentTag) return;
    scrollController.animateTo(0,
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    popularController.setCurrentTag(selected);
    if (selected.isEmpty) {
      popularController.clearBangumiList();
      if (popularController.trendList.isEmpty) {
        await popularController.queryBangumiByTrend();
      }
    } else {
      await popularController.queryBangumiByTag(type: 'init');
    }
  }
}

class _CardPlaceholder extends StatelessWidget {
  const _CardPlaceholder();

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).colorScheme.surfaceContainer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: bangumiCoverAspectRatio,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tone,
              borderRadius: BorderRadius.circular(bangumiCoverRadius),
            ),
          ),
        ),
        const SizedBox(height: 9),
        FractionallySizedBox(
          widthFactor: 0.85,
          child: Container(
            height: 12,
            decoration: BoxDecoration(
                color: tone, borderRadius: BorderRadius.circular(4)),
          ),
        ),
        const SizedBox(height: 6),
        FractionallySizedBox(
          widthFactor: 0.5,
          child: Container(
            height: 10,
            decoration: BoxDecoration(
                color: tone, borderRadius: BorderRadius.circular(4)),
          ),
        ),
      ],
    );
  }
}
