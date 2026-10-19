import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kazumi/utils/theme.dart';
import 'package:flutter/physics.dart';
import 'package:scrollview_observer/scrollview_observer.dart';

import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/roads/road_module.dart';

class EpisodeSelectionPanel extends StatefulWidget {
  const EpisodeSelectionPanel({
    super.key,
    required this.title,
    required this.roads,
    required this.selectedRoad,
    required this.selectedEpisode,
    required this.onEpisodeSelected,
    required this.downloads,
    this.onDownload,
    this.isOffline = false,
    this.isPlaying = false,
    this.disableAnimations = false,
  });

  final String title;
  final List<Road> roads;
  final int selectedRoad;
  final int selectedEpisode;
  final void Function(int episode, int road) onEpisodeSelected;
  final ValueChanged<int>? onDownload;
  final Map<String, DownloadEpisode> downloads;
  final bool isOffline;
  final bool isPlaying;
  final bool disableAnimations;

  @override
  EpisodeSelectionPanelState createState() => EpisodeSelectionPanelState();
}

class EpisodeSelectionPanelState extends State<EpisodeSelectionPanel> {
  final _scrollController = ScrollController();
  late final _observerController =
      ListObserverController(controller: _scrollController)
        ..cacheJumpIndexOffset = false;
  late int _visibleRoad = widget.selectedRoad;

  bool get _canLocate =>
      widget.selectedRoad >= 0 &&
      widget.selectedRoad < widget.roads.length &&
      widget.selectedEpisode > 0 &&
      widget.selectedEpisode <= widget.roads[widget.selectedRoad].data.length;

  double get _toolbarHeight =>
      math.max(56, MediaQuery.textScalerOf(context).scale(20) + 8);

  @override
  void didUpdateWidget(covariant EpisodeSelectionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isOffline) {
      // An automatic source change also changes the visible episode list.
      _visibleRoad = widget.selectedRoad;
    }
  }

  void _selectRoad(int road) {
    if (_visibleRoad == road) return;
    setState(() => _visibleRoad = road);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  Future<void> revealCurrentEpisode() async {
    if (!_canLocate) return;
    setState(() => _visibleRoad = widget.selectedRoad);
    // Wait for the observer to bind the new road's sliver after layout.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        !_scrollController.hasClients ||
        !_canLocate ||
        _visibleRoad != widget.selectedRoad) {
      return;
    }

    final index = widget.selectedEpisode - 1;
    final toolbarHeight = _toolbarHeight;
    final item = _observerController.observeItem(index: index);
    if (item != null) {
      final top = item.renderObject
          .localToGlobal(Offset.zero, ancestor: item.viewport)
          .dy;
      if (top >= toolbarHeight &&
          top + item.renderObject.size.height <= item.viewport.size.height) {
        return;
      }
    }
    await _observerController.jumpTo(
      index: index,
      offset: (_) => toolbarHeight,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final road = _visibleRoad >= 0 && _visibleRoad < widget.roads.length
        ? widget.roads[_visibleRoad]
        : null;
    final count = road?.data.length ?? 0;

    return LayoutBuilder(builder: (context, constraints) {
      final textScaler = MediaQuery.textScalerOf(context);
      return ListViewObserver(
        controller: _observerController,
        child: Scrollbar(
          controller: _scrollController,
          child: CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          widget.title.isEmpty ? '剧集列表' : widget.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: colors.onSurface,
                          ),
                        ),
                      ),
                      if (widget.isOffline) ...[
                        const SizedBox(height: 16),
                        _RoadSelector(
                          roads: widget.roads,
                          visibleRoad: _visibleRoad,
                          onChanged: _selectRoad,
                          disableAnimations: widget.disableAnimations,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              SliverPersistentHeader(
                pinned: true,
                delegate: _EpisodeToolbar(
                  height: _toolbarHeight,
                  color: colors.surface,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            textScaler.scale(14) > 21 ||
                                    constraints.maxWidth < 320
                                ? '$count 集'
                                : widget.isOffline
                                    ? '已缓存 · $count 集'
                                    : '全部剧集 · $count 集',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '定位当前集',
                          onPressed: _canLocate ? revealCurrentEpisode : null,
                          icon: const Icon(Icons.my_location_rounded, size: 20),
                        ),
                        if (!widget.isOffline)
                          IconButton.filledTonal(
                            tooltip: '缓存剧集',
                            onPressed: count > 0 && widget.onDownload != null
                                ? () => widget.onDownload!(_visibleRoad)
                                : null,
                            icon: const Icon(Icons.download_rounded, size: 20),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (count == 0)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: GeneralEmptyState(
                    icon: Icons.video_library_outlined,
                    title: '暂无可播放剧集',
                  ),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    0,
                    16,
                    16 + MediaQuery.paddingOf(context).bottom,
                  ),
                  sliver: SliverList.builder(
                    itemCount: count,
                    itemBuilder: (context, index) {
                      final episode = index + 1;
                      final name = index < road!.identifier.length &&
                              road.identifier[index].trim().isNotEmpty
                          ? road.identifier[index]
                          : '第$episode集';
                      return _EpisodeRow(
                        key: ValueKey('$_visibleRoad:$episode'),
                        name: name,
                        first: index == 0,
                        last: index == count - 1,
                        selected: _visibleRoad == widget.selectedRoad &&
                            episode == widget.selectedEpisode,
                        isPlaying: widget.isPlaying,
                        isOffline: widget.isOffline,
                        download: widget.downloads[road.data[index]],
                        disableAnimations: widget.disableAnimations,
                        onTap: () =>
                            widget.onEpisodeSelected(episode, _visibleRoad),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}

class _EpisodeToolbar extends SliverPersistentHeaderDelegate {
  const _EpisodeToolbar({
    required this.height,
    required this.color,
    required this.child,
  });

  final double height;
  final Color color;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => minExtent;

  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      // Fill minExtent even when desktop controls use a smaller touch target.
      SizedBox.expand(child: ColoredBox(color: color, child: child));

  @override
  bool shouldRebuild(covariant _EpisodeToolbar oldDelegate) =>
      height != oldDelegate.height ||
      color != oldDelegate.color ||
      child != oldDelegate.child;
}

class _RoadSelector extends StatefulWidget {
  const _RoadSelector({
    required this.roads,
    required this.visibleRoad,
    required this.onChanged,
    required this.disableAnimations,
  });

  final List<Road> roads;
  final int visibleRoad;
  final ValueChanged<int> onChanged;
  final bool disableAnimations;

  @override
  State<_RoadSelector> createState() => _RoadSelectorState();
}

class _RoadSelectorState extends State<_RoadSelector> {
  final _focusNode = FocusNode(debugLabel: 'Playback road selector');
  FocusNode? _focusBeforeOpen;
  bool _pointerActivation = false;

  String _name(int index) => index >= 0 && index < widget.roads.length
      ? (widget.roads[index].name.trim().isEmpty
          ? '缓存列表 ${index + 1}'
          : widget.roads[index].name)
      : '暂无缓存';

  void _toggleMenu(MenuController controller) {
    final pointerActivation = _pointerActivation;
    _pointerActivation = false;
    if (controller.isOpen) {
      controller.close();
      return;
    }
    final previousFocus = FocusManager.instance.primaryFocus;
    _focusBeforeOpen =
        pointerActivation && previousFocus == _focusNode ? null : previousFocus;
    controller.open();
  }

  void _handleClose() {
    if (!mounted) return;
    final previousFocus = _focusBeforeOpen;
    _focusBeforeOpen = null;
    if (previousFocus == null ||
        previousFocus.context?.mounted != true ||
        !previousFocus.canRequestFocus) {
      _focusNode.unfocus(
          disposition: UnfocusDisposition.previouslyFocusedChild);
      return;
    }
    if (previousFocus is FocusScopeNode) {
      // Do not restore the scope's last child: it may be this menu button.
      previousFocus.requestScopeFocus();
    } else {
      previousFocus.requestFocus();
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Widget _buildMenuItem(int index, double width) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final road = widget.roads[index];
    final selected = index == widget.visibleRoad;
    return Padding(
      padding: EdgeInsets.zero,
      child: Semantics(
        selected: selected,
        inMutuallyExclusiveGroup: true,
        child: MenuItemButton(
          key: ValueKey('road-option-$index'),
          onPressed: () => widget.onChanged(index),
          style: ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size(width, 52)),
            padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
            visualDensity: VisualDensity.standard,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            backgroundColor:
                const WidgetStatePropertyAll(Colors.transparent),
            foregroundColor: WidgetStatePropertyAll(
              selected ? colors.primary : colors.onSurface,
            ),
            textStyle: WidgetStatePropertyAll(
              theme.textTheme.bodyLarge?.copyWith(
                fontSize: 16,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
          ),
          trailingIcon: selected
              ? Icon(Icons.check_rounded, size: 20, color: colors.primary)
              : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_name(index), maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text(
                '${road.data.length} 集',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final canSwitch = widget.roads.length > 1;
    final reduceMotion =
        widget.disableAnimations || MediaQuery.disableAnimationsOf(context);
    final duration =
        reduceMotion ? Duration.zero : const Duration(milliseconds: 200);

    return LayoutBuilder(builder: (context, constraints) {
      final width =
          math.min(constraints.maxWidth, MediaQuery.sizeOf(context).width - 32);
      return MenuAnchor(
        childFocusNode: _focusNode,
        crossAxisUnconstrained: false,
        consumeOutsideTap: true,
        animated: !reduceMotion,
        onClose: _handleClose,
        alignmentOffset: const Offset(0, 8),
        style: MenuStyle(
          alignment: AlignmentDirectional.bottomStart,
          backgroundColor: WidgetStatePropertyAll(MonoPalette.of(context).menu),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(12),
          shadowColor: WidgetStatePropertyAll(
              Colors.black.withValues(alpha: 0.35)),
          padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(vertical: 6)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          )),
          minimumSize: WidgetStatePropertyAll(Size(width, 0)),
          maximumSize: WidgetStatePropertyAll(Size(
              width, math.min(400, MediaQuery.sizeOf(context).height - 32))),
          visualDensity: VisualDensity.standard,
        ),
        menuChildren: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: Text(
              '选择缓存列表',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          for (var i = 0; i < widget.roads.length; i++)
            _buildMenuItem(i, width - 16),
        ],
        builder: (context, controller, child) {
          final open = controller.isOpen;
          final foreground = colors.onSurface;
          return Semantics(
            button: canSwitch,
            expanded: canSwitch ? open : null,
            label: canSwitch ? '切换缓存列表' : null,
            child: Material(
              animationDuration: duration,
              color: open
                  ? Color.alphaBlend(colors.primary.withValues(alpha: 0.1),
                      MonoPalette.of(context).sheetGroup)
                  : MonoPalette.of(context).sheetGroup,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                focusNode: _focusNode,
                onTapUp: canSwitch ? (_) => _pointerActivation = true : null,
                onTap: canSwitch ? () => _toggleMenu(controller) : null,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '离线观看',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _name(widget.visibleRoad),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: foreground,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (canSwitch) ...[
                        const SizedBox(width: 8),
                        AnimatedRotation(
                          turns: open ? 0.5 : 0,
                          duration: duration,
                          curve: Curves.easeOutCubic,
                          child: Icon(Icons.unfold_more_rounded,
                              size: 20, color: colors.primary),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    });
  }
}

class _EpisodeRow extends StatefulWidget {
  const _EpisodeRow({
    super.key,
    required this.name,
    required this.first,
    required this.last,
    required this.selected,
    required this.isPlaying,
    required this.isOffline,
    required this.disableAnimations,
    required this.onTap,
    this.download,
  });

  final String name;
  final bool first;
  final bool last;
  final bool selected;
  final bool isPlaying;
  final bool isOffline;
  final bool disableAnimations;
  final VoidCallback onTap;
  final DownloadEpisode? download;

  @override
  State<_EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<_EpisodeRow>
    with SingleTickerProviderStateMixin {
  late final _press = AnimationController.unbounded(vsync: this);

  bool get _reduceMotion =>
      widget.disableAnimations || MediaQuery.disableAnimationsOf(context);

  void _setPressed(bool pressed) {
    final target = pressed ? 1.0 : 0.0;
    if (_reduceMotion) {
      _press.value = target;
      return;
    }
    _press.animateWith(SpringSimulation(
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: 500,
        ratio: 0.8,
      ),
      _press.value,
      target,
      _press.velocity,
    ));
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = widget.selected ? colors.primary : colors.onSurface;
    final status =
        widget.isOffline ? DownloadStatus.completed : widget.download?.status;
    final downloadLabel = switch (status) {
      DownloadStatus.completed => '已缓存',
      DownloadStatus.downloading => '正在缓存',
      DownloadStatus.failed => '缓存失败',
      DownloadStatus.paused => '缓存已暂停',
      DownloadStatus.pending => '等待缓存',
      DownloadStatus.resolving => '正在解析',
      _ => null,
    };
    final playbackLabel =
        widget.selected ? (widget.isPlaying ? '正在播放' : '当前选集') : '播放';

    final supportingText = [
      if (widget.selected) playbackLabel,
      if (!widget.isOffline && downloadLabel != null)
        status == DownloadStatus.downloading
            ? '缓存 ${(widget.download!.progressPercent.clamp(0, 1) * 100).round()}%'
            : downloadLabel,
    ].join(' · ');

    return Semantics(
      button: true,
      onTap: widget.onTap,
      selected: widget.selected,
      inMutuallyExclusiveGroup: true,
      label: '${widget.name}，$playbackLabel'
          '${downloadLabel == null ? '' : '，$downloadLabel'}',
      child: Tooltip(
        message: '${widget.name} · $playbackLabel'
            '${downloadLabel == null ? '' : ' · $downloadLabel'}',
        excludeFromSemantics: true,
        child: AnimatedBuilder(
          animation: _press,
          builder: (context, child) {
            final restShape = BorderRadius.vertical(
              top: Radius.circular(widget.first ? 12 : 0),
              bottom: Radius.circular(widget.last ? 12 : 0),
            );
            final press = _press.value.clamp(0.0, 1.0);
            final cell = MonoPalette.of(context).sheetGroup;
            // Rows form one inset group; the current episode is tinted.
            return Material(
              animationDuration: _reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              color: Color.lerp(
                  widget.selected
                      ? Color.alphaBlend(
                          colors.primary.withValues(alpha: 0.12), cell)
                      : cell,
                  Color.alphaBlend(
                      colors.onSurface.withValues(alpha: 0.06), cell),
                  press),
              borderRadius: restShape,
              clipBehavior: Clip.antiAlias,
              // Passthrough keeps the ink well as wide as the row, not the text.
              child: Stack(fit: StackFit.passthrough, children: [
                child!,
                if (!widget.first)
                  Positioned(
                    left: 16,
                    right: 0,
                    top: 0,
                    child: Container(
                        height: 0.5,
                        color: MonoPalette.of(context).hairline),
                  ),
              ]),
            );
          },
          child: InkWell(
            onTap: widget.onTap,
            onHighlightChanged: _setPressed,
            excludeFromSemantics: true,
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed) ||
                  states.contains(WidgetState.focused)) {
                return foreground.withValues(alpha: 0.1);
              }
              if (states.contains(WidgetState.hovered)) {
                return foreground.withValues(alpha: 0.08);
              }
              return null;
            }),
            child: ExcludeSemantics(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 50),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontSize: 15,
                          color: foreground,
                          fontWeight: widget.selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      if (supportingText.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          supportingText,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 12,
                            color: widget.selected
                                ? foreground.withValues(alpha: 0.8)
                                : status == DownloadStatus.failed
                                    ? colors.error
                                    : colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
