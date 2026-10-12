import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';

/// Corner radius of cover art, as on the Monogatari bookstore.
const double bangumiCoverRadius = 8;

/// Cover proportions of the poster cards.
const double bangumiCoverAspectRatio = 0.7;

// 视频卡片 - 垂直布局
class BangumiCardV extends StatelessWidget {
  const BangumiCardV({
    super.key,
    required this.bangumiItem,
    this.canTap = true,
    this.enableHero = true,
    this.showRating = false,
  });

  final BangumiItem bangumiItem;
  final bool canTap;
  final bool enableHero;

  /// Adds the score under the title.
  final bool showRating;

  /// Height of the title block under the cover for [scaler].
  static double textHeightFor(TextScaler scaler, {bool showRating = false}) {
    final clamped = scaler.clamp(maxScaleFactor: 1.1);
    return 7 +
        clamped.scale(14) * 1.35 * 2 +
        (showRating ? 2 + clamped.scale(11) * 1.4 : 0) +
        4;
  }

  @override
  Widget build(BuildContext context) {
    final cover = LayoutBuilder(builder: (context, boxConstraints) {
      final image = NetworkImgLayer(
        src: bangumiItem.images['large'] ?? '',
        width: boxConstraints.maxWidth,
        height: boxConstraints.maxHeight,
        borderRadius: BorderRadius.circular(bangumiCoverRadius),
      );
      return enableHero
          ? Hero(
              transitionOnUserGestures: true,
              flightShuttleBuilder: NetworkImgLayer.heroFlightShuttleBuilder,
              tag: bangumiItem.id,
              child: image,
            )
          : image;
    });
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          if (!canTap) {
            KazumiDialog.showToast(
              message: '编辑模式',
            );
            return;
          }
          context.pushNamed('/info/', arguments: bangumiItem);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: bangumiCoverAspectRatio,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(bangumiCoverRadius),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: cover,
              ),
            ),
            BangumiContent(bangumiItem: bangumiItem, showRating: showRating),
          ],
        ),
      ),
    );
  }
}

class BangumiContent extends StatelessWidget {
  const BangumiContent({
    super.key,
    required this.bangumiItem,
    this.showRating = false,
  });

  final BangumiItem bangumiItem;
  final bool showRating;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textScaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.1);
    final title = bangumiItem.nameCn.trim().isNotEmpty
        ? bangumiItem.nameCn
        : bangumiItem.name;
    final score = bangumiItem.ratingScore;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 7, 2, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: Text(
                title,
                textAlign: TextAlign.start,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 14,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface,
                ),
                textScaler: textScaler,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (showRating && score > 0) ...[
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(Icons.star_rounded,
                      size: 13,
                      color: theme.colorScheme.primary.withValues(alpha: 0.85)),
                  const SizedBox(width: 2),
                  Text(
                    score.toStringAsFixed(1),
                    textScaler: textScaler,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      height: 1.4,
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
