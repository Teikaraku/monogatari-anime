import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:kazumi/bean/widget/collect_button.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_subject_detail.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/theme.dart';
import 'package:skeletonizer/skeletonizer.dart';

/// Header of the detail page: title and original title, cover with the key
/// figures, and the broadcast type with Bangumi's official categories.
class BangumiInfoCardV extends StatelessWidget {
  const BangumiInfoCardV({
    super.key,
    required this.bangumiItem,
    required this.isLoading,
    required this.showRating,
    this.detail,
    this.detailLoading = false,
  });

  /// Fixed height, so the collapsing app bar can reserve it up front.
  static const double height = 352;

  final BangumiItem bangumiItem;
  final bool isLoading;
  final bool showRating;
  final BangumiSubjectDetail? detail;
  final bool detailLoading;

  Widget _caption(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );

  TextStyle? _value(BuildContext context, {bool muted = false}) =>
      Theme.of(context).textTheme.titleMedium?.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: muted
                ? MonoPalette.of(context).secondaryLabel
                : Theme.of(context).colorScheme.onSurface,
            fontFeatures: const [FontFeature.tabularFigures()],
          );

  @override
  Widget build(BuildContext context) {
    final item = bangumiItem;
    final title = item.nameCn.isEmpty ? item.name : item.nameCn;
    final original = item.name.trim();
    final showOriginal = original.isNotEmpty && original != title.trim();
    final chips = <String>[
      if (detail != null && detail!.platform.isNotEmpty) detail!.platform,
      ...?detail?.categories,
    ];
    final showChipRow = (detailLoading && detail == null) || chips.isNotEmpty;

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: Container(
        height: height,
        constraints: const BoxConstraints(maxWidth: 950),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontSize: 23, height: 1.25, fontWeight: FontWeight.w700),
            ),
            if (showOriginal)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  original,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.3,
                    color: MonoPalette.of(context).secondaryLabel,
                  ),
                ),
              ),
            const SizedBox(height: 14),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: AspectRatio(
                      aspectRatio: 0.7,
                      child: LayoutBuilder(builder: (context, boxConstraints) {
                        return Hero(
                          transitionOnUserGestures: true,
                          flightShuttleBuilder:
                              NetworkImgLayer.heroFlightShuttleBuilder,
                          tag: item.id,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.18),
                                  blurRadius: 14,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: NetworkImgLayer(
                              src: item.images['large'] ?? '',
                              width: boxConstraints.maxWidth,
                              height: boxConstraints.maxHeight,
                              borderRadius: BorderRadius.circular(8),
                              fadeInDuration: Duration.zero,
                              fadeOutDuration: Duration.zero,
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Flexible(
                    child: Skeletonizer(
                      enabled: isLoading,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Shrinks under large system fonts so the collect
                          // button stays inside the fixed-height header.
                          Flexible(
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.only(bottom: 8),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.topLeft,
                                child: _figures(context),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 120,
                            height: 40,
                            child: CollectButton.extend(bangumiItem: item),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (showChipRow) ...[
              const SizedBox(height: 14),
              SizedBox(
                height: 30,
                child: detail == null
                    ? const _ChipRowBone()
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        clipBehavior: Clip.none,
                        itemCount: chips.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, index) => _HeaderChip(
                          label: chips[index],
                          accent: index == 0 && detail!.platform.isNotEmpty,
                        ),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _figures(BuildContext context) {
    final item = bangumiItem;
    final colors = Theme.of(context).colorScheme;
    final hasVotes = item.votes > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _caption(context, '放送开始'),
        Text(
          isLoading
              ? '2000-11-11' // Skeleton Loader 占位符
              : item.airDate.isEmpty
                  ? '未定'
                  : item.airDate,
          style: _value(context, muted: !isLoading && item.airDate.isEmpty),
        ),
        const SizedBox(height: 12),
        _caption(
          context,
          !showRating
              ? '*** 人评分'
              : hasVotes || isLoading
                  ? '${item.votes} 人评分'
                  : '评分',
        ),
        if (isLoading)
          // Skeleton Loader 占位符
          Text('10.0 ********', style: _value(context))
        else if (showRating && !hasVotes)
          Text('暂无', style: _value(context, muted: true))
        else
          Row(
            children: [
              Text(
                showRating ? item.ratingScore.toStringAsFixed(1) : '***',
                style: _value(context)?.copyWith(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: 6),
              RatingBarIndicator(
                itemCount: 5,
                rating: showRating ? item.ratingScore / 2 : 0,
                unratedColor: colors.primary.withValues(alpha: 0.18),
                itemBuilder: (context, index) =>
                    Icon(Icons.star_rounded, color: colors.primary),
                itemSize: 17.0,
              ),
            ],
          ),
        const SizedBox(height: 12),
        _caption(context, 'Bangumi 排名'),
        Text(
          !showRating
              ? '***'
              : item.rank > 0 || isLoading
                  ? '#${item.rank}'
                  : '暂无',
          style: _value(context,
              muted: showRating && !isLoading && item.rank <= 0),
        ),
      ],
    );
  }
}

/// Broadcast type (accent) or official category of the subject; opens the
/// search for that category.
class _HeaderChip extends StatelessWidget {
  const _HeaderChip({required this.label, required this.accent});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final searchable = bangumiOfficialMetaTags.contains(label);
    return Material(
      color: accent
          ? colors.primary.withValues(alpha: 0.12)
          : MonoPalette.of(context).chip.withValues(alpha: 0.75),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: searchable
            ? () => context.pushNamed('/search/${Uri.encodeComponent(label)}')
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                height: 1.2,
                fontWeight: accent ? FontWeight.w600 : FontWeight.w400,
                color: accent ? colors.primary : colors.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChipRowBone extends StatelessWidget {
  const _ChipRowBone();

  @override
  Widget build(BuildContext context) {
    return Skeletonizer.zone(
      child: Row(
        children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            const Bone(width: 56, height: 30, uniRadius: 15),
          ],
        ],
      ),
    );
  }
}
