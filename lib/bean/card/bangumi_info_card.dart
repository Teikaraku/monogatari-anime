import 'package:flutter/material.dart';
import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:kazumi/bean/widget/collect_button.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:skeletonizer/skeletonizer.dart';

// 视频卡片 - 水平布局
class BangumiInfoCardV extends StatefulWidget {
  const BangumiInfoCardV({
    super.key,
    required this.bangumiItem,
    required this.isLoading,
    required this.showRating,
  });

  final BangumiItem bangumiItem;
  final bool isLoading;
  final bool showRating;

  @override
  State<BangumiInfoCardV> createState() => _BangumiInfoCardVState();
}

class _BangumiInfoCardVState extends State<BangumiInfoCardV> {
  int touchedIndex = -1;

  Widget _caption(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );

  TextStyle? _value(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium?.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
            fontFeatures: const [FontFeature.tabularFigures()],
          );

  Widget get voteBarChart {
    return Flexible(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '评分透视',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          SizedBox(height: 12),
          AspectRatio(
            aspectRatio: 2,
            child: BarChart(
              duration: Duration(milliseconds: 80),
              BarChartData(
                // alignment: BarChartAlignment.spaceEvenly,
                borderData: FlBorderData(show: false),
                gridData: FlGridData(show: false),
                barTouchData: BarTouchData(
                  touchCallback: (FlTouchEvent event, barTouchResponse) {
                    setState(() {
                      if (!event.isInterestedForInteractions ||
                          barTouchResponse == null ||
                          barTouchResponse.spot == null) {
                        touchedIndex = -1;
                        return;
                      }
                      touchedIndex =
                          barTouchResponse.spot!.touchedBarGroupIndex;
                    });
                  },
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) =>
                        Theme.of(context).colorScheme.inverseSurface,
                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                      var percentage =
                          widget.bangumiItem.votesCount[groupIndex] /
                              widget.bangumiItem.votes *
                              100;
                      return BarTooltipItem(
                        '${percentage.toStringAsFixed(2)}% (${widget.bangumiItem.votesCount[groupIndex]}人)',
                        TextStyle(
                            color:
                                Theme.of(context).colorScheme.onInverseSurface),
                      );
                    },
                  ),
                ),
                barGroups: List<BarChartGroupData>.generate(
                  10,
                  (i) => BarChartGroupData(
                    x: i + 1,
                    barRods: [
                      BarChartRodData(
                        toY: widget.bangumiItem.votesCount[i].toDouble(),
                        color: touchedIndex == i
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.25),
                        width: 18,
                        borderRadius:
                            BorderRadius.vertical(top: Radius.circular(5)),
                      )
                    ],
                    // showingTooltipIndicators: [0],
                  ),
                ),
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      getTitlesWidget: (value, meta) => SideTitleWidget(
                        meta: meta,
                        space: 10,
                        child: Text(value.toInt().toString(),
                            style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant)),
                      ),
                    ),
                  ),
                  topTitles: const AxisTitles(),
                  leftTitles: const AxisTitles(),
                  rightTitles: const AxisTitles(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 300,
      constraints: BoxConstraints(maxWidth: 950),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.bangumiItem.nameCn == ''
                ? widget.bangumiItem.name
                : (widget.bangumiItem.nameCn),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontSize: 23, height: 1.25, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 14),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: AspectRatio(
                    aspectRatio: 0.7,
                    child: LayoutBuilder(builder: (context, boxConstraints) {
                      final double maxWidth = boxConstraints.maxWidth;
                      final double maxHeight = boxConstraints.maxHeight;
                      return Hero(
                        transitionOnUserGestures: true,
                        flightShuttleBuilder:
                            NetworkImgLayer.heroFlightShuttleBuilder,
                        tag: widget.bangumiItem.id,
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
                            src: widget.bangumiItem.images['large'] ?? '',
                            width: maxWidth,
                            height: maxHeight,
                            borderRadius: BorderRadius.circular(8),
                            fadeInDuration: const Duration(milliseconds: 0),
                            fadeOutDuration: const Duration(milliseconds: 0),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
                SizedBox(width: 16),
                Flexible(
                  child: Skeletonizer(
                    enabled: widget.isLoading,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Shrink under large system font so the collect button
                        // stays inside the fixed-height card.
                        Flexible(
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.only(bottom: 8),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.topLeft,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _caption(context, '放送开始'),
                                  Text(
                                    widget.bangumiItem.airDate == ''
                                        ? '2000-11-11' // Skeleton Loader 占位符
                                        : widget.bangumiItem.airDate,
                                    style: _value(context),
                                  ),
                                  SizedBox(height: 12),
                                  _caption(
                                      context,
                                      widget.showRating
                                          ? '${widget.bangumiItem.votes} 人评分'
                                          : '*** 人评分'),
                                  if (widget.isLoading)
                                    // Skeleton Loader 占位符
                                    Text(
                                      '10.0 ********',
                                      style: _value(context),
                                    ),
                                  if (!widget.isLoading)
                                    Row(
                                      children: [
                                        Text(
                                          widget.showRating
                                              ? widget.bangumiItem.ratingScore
                                                  .toStringAsFixed(1)
                                              : '***',
                                          style: _value(context)?.copyWith(
                                            fontSize: 20,
                                            fontWeight: FontWeight.w700,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        RatingBarIndicator(
                                          itemCount: 5,
                                          rating: widget.showRating
                                              ? widget.bangumiItem.ratingScore
                                                      .toDouble() /
                                                  2
                                              : 0,
                                          unratedColor: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(alpha: 0.18),
                                          itemBuilder: (context, index) => Icon(
                                            Icons.star_rounded,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                          ),
                                          itemSize: 17.0,
                                        ),
                                      ],
                                    ),
                                  SizedBox(height: 12),
                                  _caption(context, 'Bangumi 排名'),
                                  Text(
                                    widget.showRating
                                        ? '#${widget.bangumiItem.rank}'
                                        : '***',
                                    style: _value(context),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 120,
                          height: 40,
                          child: CollectButton.extend(
                            bangumiItem: widget.bangumiItem,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.showRating &&
                    MediaQuery.sizeOf(context).width >=
                        LayoutBreakpoint.compact['width']! &&
                    !widget.isLoading)
                  voteBarChart,
              ],
            ),
          ),
        ],
      ),
    );
  }
}
