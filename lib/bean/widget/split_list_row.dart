import 'package:flutter/material.dart';

import 'package:kazumi/bean/widget/tonal_card.dart';
import 'package:kazumi/utils/theme.dart';

const double splitListOuterRadius = tonalCardRadius;
const double splitListInnerRadius = 0;
const double splitListRowGap = 0;

/// Separator inset of a plain row, aligned with its text.
const double splitListDividerInset = 16;

const Duration splitListMotionDuration = Duration(milliseconds: 250);
const Curve splitListMotionCurve = Curves.easeInOutCubic;

/// Rows that start their text further in (behind an icon) report where their
/// separator should begin.
abstract interface class SplitListDividerInset {
  double get dividerInset;
}

/// Tells the rows below whether they sit on a grouped page, where cells are
/// raised (white on grey), or on a plain surface, where they are filled grey.
class MonoGroupedScope extends InheritedWidget {
  const MonoGroupedScope({
    super.key,
    required this.grouped,
    required super.child,
  });

  final bool grouped;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MonoGroupedScope>()?.grouped ??
      false;

  @override
  bool updateShouldNotify(MonoGroupedScope oldWidget) =>
      grouped != oldWidget.grouped;
}

/// Fill of a cell in an inset group for the current backdrop: raised cells on
/// grouped pages, the sheet grey inside sheets and dialogs, and the page card
/// grey elsewhere.
Color monoCellColor(BuildContext context) {
  final palette = MonoPalette.of(context);
  if (MonoGroupedScope.of(context)) return palette.groupedCell;
  if (ModalRoute.of(context) is PopupRoute) return palette.sheetGroup;
  return Theme.of(context).colorScheme.surfaceContainer;
}

/// One cell of an inset group. Cells that continue a group ([topRadius] is the
/// inner radius) draw the hairline that separates them from the cell above.
class SplitListRow extends StatefulWidget {
  const SplitListRow({
    super.key,
    required this.child,
    this.topRadius = splitListInnerRadius,
    this.bottomRadius = splitListInnerRadius,
    this.pressedRadius = splitListOuterRadius,
    this.dividerInset,
    this.onTap,
  });

  final Widget child;

  final double topRadius;
  final double bottomRadius;

  /// Kept for callers; cells highlight instead of changing shape when pressed.
  final double pressedRadius;

  /// Start of the top separator; defaults to [splitListDividerInset] for
  /// continuing cells and none for the first cell of a group.
  final double? dividerInset;
  final VoidCallback? onTap;

  /// Forward a child InkWell's onHighlightChanged here.
  static ValueChanged<bool>? pressReporterOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_SplitRowScope>()
        ?.onPressChanged;
  }

  @override
  State<SplitListRow> createState() => _SplitListRowState();
}

class _SplitListRowState extends State<SplitListRow> {
  bool _pressed = false;

  void _reportPress(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = MonoPalette.of(context);
    final cell = monoCellColor(context);
    final highlight = Color.alphaBlend(
      (theme.brightness == Brightness.dark ? Colors.white : Colors.black)
          .withValues(alpha: 0.06),
      cell,
    );
    final inset = widget.dividerInset ??
        (widget.topRadius <= splitListInnerRadius
            ? splitListDividerInset
            : null);
    final child = widget.onTap == null
        ? widget.child
        : InkWell(
            onTap: widget.onTap,
            onHighlightChanged: _reportPress,
            child: widget.child,
          );
    return AnimatedContainer(
      duration: _pressed || MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 200),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _pressed ? highlight : cell,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(widget.topRadius),
          bottom: Radius.circular(widget.bottomRadius),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Theme(
          data: theme.copyWith(
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.transparent,
            hoverColor: colors.onSurface.withValues(alpha: 0.03),
          ),
          child: ListTileTheme(
            data: theme.listTileTheme.copyWith(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              titleTextStyle:
                  theme.textTheme.bodyLarge?.copyWith(color: colors.onSurface),
              subtitleTextStyle: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12,
                color: colors.onSurfaceVariant,
              ),
            ),
            child: _SplitRowScope(
              onPressChanged: _reportPress,
              child: inset == null
                  ? child
                  : Stack(
                      children: [
                        child,
                        Positioned(
                          left: inset,
                          right: 0,
                          top: 0,
                          child: Container(height: 0.5, color: palette.hairline),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SplitRowScope extends InheritedWidget {
  const _SplitRowScope({required this.onPressChanged, required super.child});

  final ValueChanged<bool> onPressChanged;

  // The callback always targets the same state.
  @override
  bool updateShouldNotify(_SplitRowScope oldWidget) => false;
}

class SplitListGroup extends StatelessWidget {
  const SplitListGroup({
    super.key,
    required this.children,
    this.outerRadius = splitListOuterRadius,
  });

  final List<Widget> children;

  final double outerRadius;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < children.length; i++)
          SplitListRow(
            topRadius: i == 0 ? outerRadius : splitListInnerRadius,
            bottomRadius:
                i == children.length - 1 ? outerRadius : splitListInnerRadius,
            pressedRadius: outerRadius,
            dividerInset: i == 0
                ? null
                : switch (children[i]) {
                    SplitListDividerInset row => row.dividerInset,
                    _ => splitListDividerInset,
                  },
            child: children[i],
          ),
      ],
    );
  }
}
