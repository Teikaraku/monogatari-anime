import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:window_manager/window_manager.dart';

import 'package:kazumi/bean/appbar/drag_to_move_bar.dart' as dtb;
import 'package:kazumi/bean/card/bangumi_info_card.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/widget/collect_button.dart';
import 'package:kazumi/bean/widget/embedded_native_control_area.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_subject_detail.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/pages/info/info_actions_menu.dart';
import 'package:kazumi/pages/info/info_catalog_prefetch.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/pages/info/info_tabview.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/platform/desktop_window_config.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/device.dart';

class InfoPage extends StatefulWidget {
  const InfoPage({
    super.key,
    required this.inputBangumiItem,
    required this.infoController,
  });

  final BangumiItem inputBangumiItem;
  final InfoController infoController;

  @override
  State<InfoPage> createState() => _InfoPageState();
}

class _InfoPageState extends State<InfoPage>
    with SingleTickerProviderStateMixin {
  static const List<String> _infoTabs = <String>['概览', '演职人员'];
  static const Duration _minimumBangumiInfoLoadingDuration = Duration(
    milliseconds: 600,
  );

  InfoController get infoController => widget.infoController;
  // Detail browsing does not contact playback providers. Resolve their
  // catalogs only after the user explicitly plays or downloads online video.
  late final _catalogPrefetch = InfoCatalogPrefetch();
  late int _subjectRevision;
  late final TabController infoTabController;
  late final bool showRating;

  bool charactersIsLoading = false;
  bool charactersQueryTimeout = false;
  bool charactersIsEmpty = false;
  bool staffIsLoading = false;
  bool staffQueryTimeout = false;
  bool staffIsEmpty = false;
  bool _showBangumiInfoSkeleton = false;
  BangumiSubjectDetail? _subjectDetail;
  bool _detailLoading = true;

  /// Null while loading.
  List<EpisodeInfo>? _episodes;
  bool _episodesFailed = false;

  bool get _isShowingBangumiInfoSkeleton =>
      infoController.isLoading || _showBangumiInfoSkeleton;

  bool _needsBangumiInfoRefresh(BangumiItem bangumiItem) {
    final votesCount = bangumiItem.votesCount;
    final missingVoteDistribution =
        votesCount.isEmpty || bangumiItem.votes <= 0 || votesCount.length < 10;
    return bangumiItem.summary == '' || missingVoteDistribution;
  }

  Future<void> loadCharacters() async {
    if (charactersIsLoading) return;
    final id = infoController.bangumiItem.id;
    final revision = _subjectRevision;
    setState(() {
      charactersIsLoading = true;
      charactersQueryTimeout = false;
      charactersIsEmpty = false;
    });
    try {
      await infoController.queryBangumiCharactersByID(id);
      if (_isCurrentSubject(id, revision)) {
        setState(() {
          charactersIsLoading = false;
          if (infoController.characterList.isEmpty) {
            charactersIsEmpty = true;
          }
        });
      }
    } catch (e) {
      KazumiLogger().e('InfoPage: failed to load characters', error: e);
      if (_isCurrentSubject(id, revision)) {
        setState(() {
          charactersIsLoading = false;
          charactersQueryTimeout = true;
        });
      }
    }
  }

  Future<void> loadStaff() async {
    if (staffIsLoading) return;
    final id = infoController.bangumiItem.id;
    final revision = _subjectRevision;
    setState(() {
      staffIsLoading = true;
      staffQueryTimeout = false;
      staffIsEmpty = false;
    });
    try {
      await infoController.queryBangumiStaffsByID(id);
      if (_isCurrentSubject(id, revision)) {
        setState(() {
          staffIsLoading = false;
          if (infoController.staffList.isEmpty) {
            staffIsEmpty = true;
          }
        });
      }
    } catch (e) {
      KazumiLogger().e('InfoPage: failed to load staff', error: e);
      if (_isCurrentSubject(id, revision)) {
        setState(() {
          staffIsLoading = false;
          staffQueryTimeout = true;
        });
      }
    }
  }

  Future<void> loadRelations() async {
    try {
      await infoController.queryBangumiRelationsByID(
        infoController.bangumiItem.id,
      );
    } catch (e) {
      KazumiLogger().e('InfoPage: failed to load relations', error: e);
    }
  }

  Future<void> loadEpisodes() async {
    final id = infoController.bangumiItem.id;
    final revision = _subjectRevision;
    try {
      final episodes = await infoController.queryBangumiMainEpisodesByID(id);
      if (_isCurrentSubject(id, revision)) {
        setState(() {
          _episodes = episodes;
          _episodesFailed = false;
        });
      }
    } catch (e) {
      KazumiLogger().e('InfoPage: failed to load episodes', error: e);
      if (_isCurrentSubject(id, revision)) setState(() => _episodesFailed = true);
    }
  }

  void _retryEpisodes() {
    setState(() {
      _episodes = null;
      _episodesFailed = false;
    });
    loadEpisodes();
  }

  @override
  void initState() {
    super.initState();
    _initializeSubject();
    infoTabController = TabController(length: _infoTabs.length, vsync: this);
    showRating = GStorage.getSetting(SettingsKeys.showRating);
    infoTabController.addListener(onInfoTabChanged);
  }

  void _initializeSubject() {
    _subjectRevision = _catalogPrefetch.beginSubject(widget.inputBangumiItem.id);
    infoController.bangumiItem = widget.inputBangumiItem;
    infoController.characterList.clear();
    infoController.staffList.clear();
    infoController.clearRelations();
    _subjectDetail = null;
    _detailLoading = true;
    _episodes = null;
    _episodesFailed = false;
    charactersIsLoading = false;
    charactersQueryTimeout = false;
    charactersIsEmpty = false;
    staffIsLoading = false;
    staffQueryTimeout = false;
    staffIsEmpty = false;
    // Always fetch the subject: the detail fields come only from this request.
    final needsRefresh = _needsBangumiInfoRefresh(infoController.bangumiItem);
    _showBangumiInfoSkeleton = needsRefresh;
    _loadBangumiInfo(showSkeleton: needsRefresh);
    loadEpisodes();
    loadRelations();
  }

  @override
  void didUpdateWidget(covariant InfoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inputBangumiItem.id != widget.inputBangumiItem.id ||
        oldWidget.infoController != widget.infoController) {
      _initializeSubject();
      infoTabController.index = 0;
    }
  }

  void onInfoTabChanged() {
    if (infoTabController.index != 1) return;
    if (infoController.characterList.isEmpty &&
        !charactersIsLoading &&
        !charactersIsEmpty &&
        !charactersQueryTimeout) {
      loadCharacters();
    }
    if (infoController.staffList.isEmpty &&
        !staffIsLoading &&
        !staffIsEmpty &&
        !staffQueryTimeout) {
      loadStaff();
    }
  }

  @override
  void dispose() {
    _catalogPrefetch.dispose();
    infoTabController.removeListener(onInfoTabChanged);
    infoController.characterList.clear();
    infoController.staffList.clear();
    infoController.clearRelations();
    infoTabController.dispose();
    super.dispose();
  }

  Future<void> _loadBangumiInfo({required bool showSkeleton}) async {
    final loadingStartedAt = DateTime.now();
    final id = infoController.bangumiItem.id;
    final revision = _subjectRevision;
    BangumiSubjectDetail? detail;
    try {
      // Attach metadata without replacing rendered image URLs.
      detail = showSkeleton
          ? await infoController.queryBangumiInfoByID(id, type: 'attach')
          : await infoController.refreshBangumiInfoByID(id);
      if (detail != null && _isCurrentSubject(id, revision)) {
        _catalogPrefetch.afterDetailsApplied(
          revision,
          infoController.bangumiItem,
        );
      }
    } catch (e) {
      KazumiLogger().e(
        'InfoPage: failed to query bangumi info by ID',
        error: e,
      );
    } finally {
      if (_isCurrentSubject(id, revision) && showSkeleton) {
        await _waitForMinimumBangumiInfoLoadingDuration(loadingStartedAt);
      }
      if (_isCurrentSubject(id, revision)) {
        setState(() {
          _showBangumiInfoSkeleton = false;
          _subjectDetail = detail;
          _detailLoading = false;
        });
      }
    }
  }

  bool _isCurrentSubject(int id, int revision) =>
      mounted && _catalogPrefetch.isCurrent(revision, id);

  Future<void> _waitForMinimumBangumiInfoLoadingDuration(
    DateTime loadingStartedAt,
  ) async {
    final elapsed = DateTime.now().difference(loadingStartedAt);
    final remaining = _minimumBangumiInfoLoadingDuration - elapsed;
    if (remaining > Duration.zero) {
      await Future.delayed(remaining);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showWindowButton = DesktopWindowConfig.showWindowButton;
    final topOffset = Platform.isMacOS && showWindowButton ? 22.0 : 0.0;
    return Scaffold(
      body: NestedScrollView(
        headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) {
          return <Widget>[
            SliverOverlapAbsorber(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
              sliver: SliverAppBar.medium(
                title: EmbeddedNativeControlArea(
                  child: dtb.DragToMoveArea(
                    child: Container(
                      width: double.infinity,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        infoController.bangumiItem.nameCn == ''
                            ? infoController.bangumiItem.name
                            : infoController.bangumiItem.nameCn,
                      ),
                    ),
                  ),
                ),
                automaticallyImplyLeading: false,
                scrolledUnderElevation: 0.0,
                leading: EmbeddedNativeControlArea(
                  child: IconButton(
                    onPressed: () {
                      context.maybePop();
                    },
                    icon: Icon(Icons.arrow_back),
                  ),
                ),
                actions: [
                  if (innerBoxIsScrolled)
                    EmbeddedNativeControlArea(
                      child: CollectButton(
                        bangumiItem: infoController.bangumiItem,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  EmbeddedNativeControlArea(
                    child: InfoActionsMenu(
                      bangumiItem: infoController.bangumiItem,
                    ),
                  ),
                  if (isDesktop() && !showWindowButton)
                    CloseButton(onPressed: () => windowManager.close()),
                  SizedBox(width: 8),
                ],
                toolbarHeight: kToolbarHeight + topOffset,
                stretch: true,
                centerTitle: false,
                expandedHeight:
                    BangumiInfoCardV.height +
                    8 +
                    kTextTabBarHeight +
                    kToolbarHeight +
                    topOffset,
                collapsedHeight:
                    kTextTabBarHeight +
                    kToolbarHeight +
                    MediaQuery.paddingOf(context).top +
                    topOffset,
                flexibleSpace: FlexibleSpaceBar(
                  collapseMode: CollapseMode.pin,
                  background: Observer(
                    builder: (context) {
                      final showBangumiInfoSkeleton =
                          _isShowingBangumiInfoSkeleton;
                      return Stack(
                        children: [
                          if (!showBangumiInfoSkeleton)
                            Positioned.fill(
                              bottom: kTextTabBarHeight,
                              child: IgnorePointer(
                                child: _InfoHeaderBackground(
                                  imageUrl:
                                      infoController
                                          .bangumiItem
                                          .images['large'] ??
                                      '',
                                ),
                              ),
                            ),
                          _CollapsingHeader(
                            toolbarBottom:
                                MediaQuery.paddingOf(context).top +
                                kToolbarHeight +
                                topOffset,
                            child: SafeArea(
                              bottom: false,
                              child: EmbeddedNativeControlArea(
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      16,
                                      kToolbarHeight + topOffset,
                                      16,
                                      0,
                                    ),
                                    child: BangumiInfoCardV(
                                      bangumiItem: infoController.bangumiItem,
                                      isLoading: showBangumiInfoSkeleton,
                                      showRating: showRating,
                                      detail: _subjectDetail,
                                      detailLoading: _detailLoading,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                forceElevated: innerBoxIsScrolled,
                bottom: TabBar(
                  controller: infoTabController,
                  isScrollable: true,
                  tabAlignment: TabAlignment.center,
                  dividerHeight: 0,
                  tabs: _infoTabs.map((name) => Tab(text: name)).toList(),
                ),
              ),
            ),
          ];
        },
        body: Observer(
          builder: (context) {
            final showBangumiInfoSkeleton = _isShowingBangumiInfoSkeleton;
            return InfoTabView(
              tabController: infoTabController,
              bangumiItem: infoController.bangumiItem,
              isLoading: showBangumiInfoSkeleton,
              showRating: showRating,
              subjectDetail: _subjectDetail,
              detailLoading: _detailLoading,
              episodes: _episodes,
              episodesFailed: _episodesFailed,
              loadEpisodes: _retryEpisodes,
              characterList: infoController.characterList,
              charactersQueryTimeout: charactersQueryTimeout,
              charactersIsEmpty: charactersIsEmpty,
              loadCharacters: loadCharacters,
              staffList: infoController.staffList,
              staffQueryTimeout: staffQueryTimeout,
              staffIsEmpty: staffIsEmpty,
              loadStaff: loadStaff,
              relationList: infoController.relationList,
              relationsQueryTimeout: infoController.relationsQueryTimeout,
              relationsHasLoaded: infoController.relationsHasLoaded,
              loadRelations: loadRelations,
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: '开始观看',
        onPressed: () {
          context.pushNamed(
            '/video/',
            arguments: OnlineVideoPlaybackArgs(
              bangumiItem: infoController.bangumiItem,
            ),
          );
        },
        label: const Text('开始观看'),
        icon: const Icon(Icons.play_arrow_rounded),
      ),
    );
  }
}

/// Fades the header out as the app bar collapses and clips it at the toolbar's
/// bottom edge, so the title never slides under the back button.
class _CollapsingHeader extends StatelessWidget {
  const _CollapsingHeader({required this.toolbarBottom, required this.child});

  /// Bottom of the toolbar, measured from the top of the app bar.
  final double toolbarBottom;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final settings = context
        .dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
    var scrolled = 0.0;
    var collapse = 0.0;
    if (settings != null) {
      // CollapseMode.pin moves the background up by exactly this much.
      scrolled = settings.maxExtent - settings.currentExtent;
      final range = settings.maxExtent - settings.minExtent;
      collapse = range <= 0 ? 0 : (scrolled / range).clamp(0.0, 1.0);
    }
    return ClipRect(
      clipper: _TopInsetClipper(math.max(0, toolbarBottom + scrolled)),
      // Stay opaque through the first half; the clip already keeps the
      // toolbar clear, the fade only eases the last stretch.
      child: Opacity(
        opacity: ((1 - collapse) / 0.45).clamp(0.0, 1.0),
        child: child,
      ),
    );
  }
}

class _TopInsetClipper extends CustomClipper<Rect> {
  const _TopInsetClipper(this.top);

  final double top;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, math.min(top, size.height), size.width, size.height);

  @override
  bool shouldReclip(_TopInsetClipper oldClipper) => oldClipper.top != top;
}

class _InfoHeaderBackground extends StatelessWidget {
  const _InfoHeaderBackground({required this.imageUrl});

  static const double _downsample = 0.5;
  static const double _blurSigma = 15.0;
  static const double _opacity = 0.4;
  static const double _edgeBleed = 32.0;
  static const double _bottomFeatherHeight = 48.0;

  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    if (imageUrl.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        if (width <= 0 || height <= 0) {
          return const SizedBox.shrink();
        }

        final rasterWidth = width * _downsample;
        final rasterHeight = (height + _edgeBleed) * _downsample;

        final backgroundColor = Theme.of(context).scaffoldBackgroundColor;

        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ShaderMask(
                shaderCallback: (bounds) {
                  return const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.white, Colors.transparent],
                    stops: [0.8, 1],
                  ).createShader(bounds);
                },
                child: Align(
                  alignment: Alignment.topCenter,
                  child: RepaintBoundary(
                    child: Transform.scale(
                      scale: 1 / _downsample,
                      alignment: Alignment.topCenter,
                      filterQuality: FilterQuality.low,
                      child: SizedBox(
                        width: rasterWidth,
                        height: rasterHeight,
                        child: ImageFiltered(
                          imageFilter: ImageFilter.blur(
                            sigmaX: _blurSigma * _downsample,
                            sigmaY: _blurSigma * _downsample,
                          ),
                          child: NetworkImgLayer(
                            src: imageUrl,
                            width: rasterWidth,
                            height: rasterHeight,
                            fadeInDuration: Duration.zero,
                            fadeOutDuration: Duration.zero,
                            filterQuality: FilterQuality.low,
                            color: Colors.white.withValues(alpha: _opacity),
                            colorBlendMode: BlendMode.modulate,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: _bottomFeatherHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        backgroundColor.withValues(alpha: 0),
                        backgroundColor.withValues(alpha: 0.55),
                        backgroundColor,
                      ],
                      stops: const [0, 0.72, 1],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
