import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/card/cast_tile.dart';
import 'package:kazumi/bean/card/character_card.dart';
import 'package:kazumi/bean/card/staff_card.dart';
import 'package:kazumi/pages/collect/episode_picker_sheet.dart';
import 'package:kazumi/pages/info/info_overview_sections.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_relation.dart';
import 'package:kazumi/modules/bangumi/bangumi_subject_detail.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/modules/characters/character_item.dart';
import 'package:kazumi/modules/staff/staff_item.dart';

class InfoTabView extends StatefulWidget {
  const InfoTabView({
    super.key,
    required this.tabController,
    required this.bangumiItem,
    required this.isLoading,
    required this.showRating,
    required this.subjectDetail,
    required this.detailLoading,
    required this.episodes,
    required this.episodesFailed,
    required this.loadEpisodes,
    required this.characterList,
    required this.charactersQueryTimeout,
    required this.charactersIsEmpty,
    required this.loadCharacters,
    required this.staffList,
    required this.staffQueryTimeout,
    required this.staffIsEmpty,
    required this.loadStaff,
    required this.relationList,
    required this.relationsQueryTimeout,
    required this.relationsHasLoaded,
    required this.loadRelations,
    this.watched = const {},
    this.onPlayEpisode,
    this.onMark,
    this.note,
    this.onEditNote,
  });

  /// Episode numbers (第 N 话) counted as watched.
  final Set<int> watched;
  final ValueChanged<int>? onPlayEpisode;
  final EpisodeMarkCallback? onMark;

  /// The user's own line about the show.
  final String? note;
  final VoidCallback? onEditNote;

  final TabController tabController;
  final BangumiItem bangumiItem;
  final bool isLoading;
  final bool showRating;
  final BangumiSubjectDetail? subjectDetail;
  final bool detailLoading;

  /// Null while loading.
  final List<EpisodeInfo>? episodes;
  final bool episodesFailed;
  final VoidCallback loadEpisodes;
  final List<CharacterItem> characterList;
  final bool charactersQueryTimeout;
  final bool charactersIsEmpty;
  final Future<void> Function() loadCharacters;
  final List<StaffFullItem> staffList;
  final bool staffQueryTimeout;
  final bool staffIsEmpty;
  final Future<void> Function() loadStaff;
  final List<BangumiRelation> relationList;
  final bool relationsQueryTimeout;
  final bool relationsHasLoaded;
  final Future<void> Function() loadRelations;

  @override
  State<InfoTabView> createState() => _InfoTabViewState();
}

class _InfoTabViewState extends State<InfoTabView> {
  static const double maxWidth = 950.0;
  static const double _sectionGap = 28;

  /// Room below the content for the floating "开始观看" button.
  static const double _fabClearance = 96;
  bool fullIntro = false;
  bool fullTag = false;

  double _contentWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width > maxWidth + 32 ? maxWidth : width - 32;
  }

  Widget _centered(BuildContext context, Widget child) {
    return Center(
      child: SizedBox(width: _contentWidth(context), child: child),
    );
  }

  Widget get _summarySection {
    final summary = widget.bangumiItem.summary.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const InfoSectionTitle('简介'),
        const SizedBox(height: 8),
        LayoutBuilder(builder: (context, constraints) {
          final style = _summaryStyle(context);
          final scaler = MediaQuery.textScalerOf(context);
          final tp = TextPainter(
              text: TextSpan(text: summary, style: style),
              textDirection: TextDirection.ltr,
              textScaler: scaler);
          tp.layout(maxWidth: constraints.maxWidth);
          final numLines = tp.computeLineMetrics().length;
          tp.dispose();
          final text = SelectableText(
            summary,
            textAlign: TextAlign.start,
            style: style,
            scrollBehavior: const ScrollBehavior().copyWith(scrollbars: false),
            scrollPhysics: const NeverScrollableScrollPhysics(),
            selectionHeightStyle: ui.BoxHeightStyle.max,
          );
          if (numLines <= 5) return text;
          // Collapse long synopses to five lines.
          final collapsedHeight = scaler.scale(15) * 1.5 * 5 + 2;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(
                height: fullIntro ? null : collapsedHeight,
                width: constraints.maxWidth,
                child: text,
              ),
              TextButton(
                onPressed: () => setState(() => fullIntro = !fullIntro),
                child: Text(fullIntro ? '收起' : '展开全部'),
              ),
            ],
          );
        }),
      ],
    );
  }

  Widget get _tagSection {
    final tags = widget.bangumiItem.tags;
    final collapsed = !fullTag && tags.length >= 13;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const InfoSectionTitle('标签'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8.0,
          runSpacing: 8,
          children: [
            for (var i = 0; i < (collapsed ? 12 : tags.length); i++)
              _InfoTagChip(
                label: tags[i].name,
                count: tags[i].count,
                onPressed: () {
                  final tagName = Uri.encodeComponent(tags[i].name);
                  context.pushNamed('/search/$tagName');
                },
              ),
            if (collapsed)
              _InfoTagChip(
                label: '更多',
                accentLabel: true,
                onPressed: () => setState(() => fullTag = true),
              ),
          ],
        ),
      ],
    );
  }

  Widget get _loadingBody {
    return Skeletonizer.zone(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Bone.text(fontSize: 18, width: 50),
          const SizedBox(height: 10),
          Bone(height: 92, uniRadius: 16),
          const SizedBox(height: _sectionGap),
          Bone.text(fontSize: 18, width: 50),
          const SizedBox(height: 8),
          Bone.multiText(lines: 5),
          const SizedBox(height: _sectionGap),
          Bone.text(fontSize: 18, width: 50),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8.0,
            runSpacing: 8.0,
            children:
                List.generate(5, (_) => Bone.button(uniRadius: 16, height: 30)),
          ),
        ],
      ),
    );
  }

  /// Sections with nothing to show are left out, not drawn empty.
  List<Widget> get _overviewSections {
    final item = widget.bangumiItem;
    final detail = widget.subjectDetail;
    return [
      if (widget.note != null)
        InfoNoteRow(note: widget.note!, onEdit: widget.onEditNote),
      if (widget.episodesFailed ||
          infoHasEpisodeSection(widget.episodes, detail))
        InfoEpisodeSection(
          episodes: widget.episodes,
          failed: widget.episodesFailed,
          onRetry: widget.loadEpisodes,
          detail: detail,
          watched: widget.watched,
          onPlayEpisode: widget.onPlayEpisode,
          onMark: widget.onMark,
        ),
      if (item.summary.trim().isNotEmpty) _summarySection,
      if (widget.showRating && infoHasRatingDistribution(item))
        InfoRatingSection(bangumiItem: item),
      if (item.tags.isNotEmpty) _tagSection,
      if (infoHasRelationSection(
        hasLoaded: widget.relationsHasLoaded,
        failed: widget.relationsQueryTimeout,
        count: widget.relationList.length,
      ))
        InfoRelationsSection(
          relations: widget.relationList,
          hasLoaded: widget.relationsHasLoaded,
          failed: widget.relationsQueryTimeout,
          onRetry: widget.loadRelations,
        ),
      if (infoHasFactsSection(detail, widget.detailLoading))
        InfoFactsSection(detail: detail, loading: widget.detailLoading),
    ];
  }

  Widget get _overviewBody {
    if (widget.isLoading) return _loadingBody;
    final sections = _overviewSections;
    if (sections.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 48),
        child: GeneralEmptyState(
          icon: Icons.info_outline_rounded,
          title: '暂无条目资料',
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < sections.length; i++) ...[
          if (i > 0) const SizedBox(height: _sectionGap),
          sections[i],
        ],
      ],
    );
  }

  Widget get _overviewTab {
    return Builder(
      // Resolve the overlap handle inside the NestedScrollView.
      builder: (BuildContext context) {
        return CustomScrollView(
          scrollBehavior: const ScrollBehavior().copyWith(scrollbars: false),
          key: const PageStorageKey<String>('概览'),
          slivers: <Widget>[
            SliverOverlapInjector(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
            ),
            SliverSafeArea(
              top: false,
              bottom: false,
              sliver: SliverPadding(
                padding: const EdgeInsets.fromLTRB(0, 16, 0, _fabClearance),
                sliver: SliverToBoxAdapter(
                  child: _centered(context, _overviewBody),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _castSection<T>({
    required String title,
    required List<T> items,
    required bool failed,
    required bool empty,
    required int boneCount,
    required String failedMessage,
    required VoidCallback onRetry,
    required Widget Function(T item) itemBuilder,
  }) {
    if (empty) return const [];
    final Widget header = SliverToBoxAdapter(
      child: _centered(
        context,
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 4),
          child: InfoSectionTitle(
            items.isEmpty ? title : '$title  ${items.length}',
          ),
        ),
      ),
    );
    if (items.isNotEmpty) {
      return [
        header,
        _castGrid(
          itemCount: items.length,
          itemBuilder: (index) => itemBuilder(items[index]),
        ),
      ];
    }
    if (failed) {
      return [
        header,
        SliverToBoxAdapter(
          child: _centered(
            context,
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: InfoInlineRetry(message: failedMessage, onRetry: onRetry),
            ),
          ),
        ),
      ];
    }
    return [
      header,
      _castGrid(
        itemCount: boneCount,
        itemBuilder: (_) => Skeletonizer.zone(
          child: const Bone(uniRadius: 14),
        ),
      ),
    ];
  }

  /// Two columns on phones, more on wider windows.
  Widget _castGrid({
    required int itemCount,
    required Widget Function(int index) itemBuilder,
  }) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        final content = width > maxWidth + 32 ? maxWidth : width - 32;
        final side = (width - content) / 2;
        final columns = content >= 900
            ? 4
            : content >= 600
                ? 3
                : 2;
        final textScaler =
            MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(side, 8, side, 0),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              mainAxisExtent: textScaler.scale(CastTile.height),
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.3,
                child: itemBuilder(index),
              ),
              childCount: itemCount,
            ),
          ),
        );
      },
    );
  }

  Widget get _castTab {
    return Builder(
      builder: (BuildContext context) {
        final nothing = widget.charactersIsEmpty && widget.staffIsEmpty;
        return CustomScrollView(
          scrollBehavior: const ScrollBehavior().copyWith(scrollbars: false),
          key: const PageStorageKey<String>('演职人员'),
          slivers: <Widget>[
            SliverOverlapInjector(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
            ),
            if (nothing)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: GeneralEmptyState(
                  icon: Icons.people_alt_rounded,
                  title: '暂无演职人员信息',
                ),
              )
            else ...[
              ..._castSection<CharacterItem>(
                title: '角色',
                items: widget.characterList,
                failed: widget.charactersQueryTimeout,
                empty: widget.charactersIsEmpty,
                boneCount: 4,
                failedMessage: '角色加载失败',
                onRetry: widget.loadCharacters,
                itemBuilder: (item) => CharacterCard(characterItem: item),
              ),
              ..._castSection<StaffFullItem>(
                title: '制作人员',
                items: widget.staffList,
                failed: widget.staffQueryTimeout,
                empty: widget.staffIsEmpty,
                boneCount: 6,
                failedMessage: '制作人员加载失败',
                onRetry: widget.loadStaff,
                itemBuilder: (item) => StaffCard(staffFullItem: item),
              ),
              const SliverToBoxAdapter(
                child: SizedBox(height: _fabClearance),
              ),
            ],
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return TabBarView(
      controller: widget.tabController,
      children: [
        _overviewTab,
        _castTab,
      ],
    );
  }
}

TextStyle? _summaryStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontSize: 15,
          height: 1.5,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );

/// An outlined tag capsule with its vote count in the accent colour.
class _InfoTagChip extends StatelessWidget {
  const _InfoTagChip({
    required this.label,
    required this.onPressed,
    this.count,
    this.accentLabel = false,
  });

  final String label;
  final int? count;
  final bool accentLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      shape: StadiumBorder(side: BorderSide(color: colors.outlineVariant)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                text: label,
                style: TextStyle(
                  color: accentLabel ? colors.primary : colors.onSurface,
                  fontWeight: accentLabel ? FontWeight.w500 : null,
                ),
              ),
              if (count != null)
                TextSpan(
                  text: '  $count',
                  style: TextStyle(
                    color: colors.primary,
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ]),
            style: const TextStyle(fontSize: 13, height: 1.3),
          ),
        ),
      ),
    );
  }
}
