part of 'timeline_page.dart';

enum _NodeState { normal, aired, next }

/// Shows that air at the same local time in one timetable column.
class _TimelineGroup {
  _TimelineGroup({required this.time, required this.dayPrefix});

  /// "20:30" in the device's time zone.
  final String time;

  /// "周五" when the time falls on another local day than the column.
  final String? dayPrefix;
  final items = <BangumiItem>[];
}

/// One node of the timetable: the time and a dot on the rail at the left, the
/// shows of that time at the right. The rail line runs through the node's
/// bottom gap, so consecutive nodes join up.
class _TimelineNode extends StatelessWidget {
  const _TimelineNode({
    required this.group,
    required this.state,
    required this.isFirst,
    required this.isLast,
    required this.columns,
    required this.cardHeight,
    required this.cardBuilder,
  });

  static const double railWidth = 76;
  static const double _lineX = 62;
  static const double _labelTop = 10;
  static const double _gap = 12;
  static const double _nodeGap = 20;

  final _TimelineGroup group;
  final _NodeState state;
  final bool isFirst;
  final bool isLast;
  final int columns;
  final double cardHeight;
  final Widget Function(BangumiItem item) cardBuilder;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = MonoPalette.of(context);
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    final prefixHeight =
        group.dayPrefix == null ? 0.0 : scaler.scale(11) * 1.3;
    final timeHeight = scaler.scale(16) * 1.2;
    final dotY = _labelTop + prefixHeight + timeHeight / 2;

    final timeColor = switch (state) {
      _NodeState.aired => palette.secondaryLabel,
      _NodeState.next => colors.primary,
      _NodeState.normal => colors.onSurface,
    };
    final caption = switch (state) {
      _NodeState.aired => '已更新',
      _NodeState.next => '即将更新',
      _NodeState.normal => null,
    };

    final rows = <List<BangumiItem>>[
      for (var i = 0; i < group.items.length; i += columns)
        group.items.sublist(i, (i + columns).clamp(0, group.items.length)),
    ];

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: railWidth,
            child: CustomPaint(
              painter: _RailPainter(
                lineX: _lineX,
                dotY: dotY,
                drawTop: !isFirst,
                drawBottom: !isLast,
                lineColor: palette.hairline,
                dotColor: state == _NodeState.aired
                    ? palette.tertiaryLabel
                    : colors.primary,
                filled: state != _NodeState.normal,
                halo: state == _NodeState.next,
              ),
              child: Padding(
                padding: const EdgeInsets.only(top: _labelTop, right: 24),
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: scaler),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (group.dayPrefix != null)
                        Text(
                          group.dayPrefix!,
                          style: TextStyle(
                              fontSize: 11,
                              height: 1.3,
                              color: palette.secondaryLabel),
                        ),
                      Text(
                        group.time,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 16,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: timeColor,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      if (caption != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            caption,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 10,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                              color: state == _NodeState.next
                                  ? colors.primary
                                  : palette.secondaryLabel,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : _nodeGap),
              child: Column(
                children: [
                  for (var r = 0; r < rows.length; r++) ...[
                    if (r > 0) const SizedBox(height: _gap),
                    SizedBox(
                      height: cardHeight,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var c = 0; c < columns; c++) ...[
                            if (c > 0) const SizedBox(width: _gap),
                            Expanded(
                              child: c < rows[r].length
                                  ? cardBuilder(rows[r][c])
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RailPainter extends CustomPainter {
  const _RailPainter({
    required this.lineX,
    required this.dotY,
    required this.drawTop,
    required this.drawBottom,
    required this.lineColor,
    required this.dotColor,
    required this.filled,
    required this.halo,
  });

  static const double _radius = 5;
  static const double _clearance = 4;

  final double lineX;
  final double dotY;
  final bool drawTop;
  final bool drawBottom;
  final Color lineColor;
  final Color dotColor;
  final bool filled;
  final bool halo;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = lineColor
      ..strokeWidth = 1.5;
    if (drawTop) {
      canvas.drawLine(Offset(lineX, 0),
          Offset(lineX, dotY - _radius - _clearance), line);
    }
    if (drawBottom) {
      canvas.drawLine(Offset(lineX, dotY + _radius + _clearance),
          Offset(lineX, size.height), line);
    }
    final center = Offset(lineX, dotY);
    if (halo) {
      canvas.drawCircle(center, _radius + 4,
          Paint()..color = dotColor.withValues(alpha: 0.18));
    }
    canvas.drawCircle(
      center,
      filled ? _radius : _radius - 1,
      Paint()
        ..color = dotColor
        ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.dotY != dotY ||
      old.drawTop != drawTop ||
      old.drawBottom != drawBottom ||
      old.lineColor != lineColor ||
      old.dotColor != dotColor ||
      old.filled != filled ||
      old.halo != halo;
}
