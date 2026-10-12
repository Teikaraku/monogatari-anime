part of 'timeline_page.dart';

/// The weekdays as an iOS segmented control: a grey track with a raised thumb
/// on the chosen day.
class _TimelineWeekSelector extends StatelessWidget {
  const _TimelineWeekSelector({
    required this.counts,
    this.todayIndex,
    this.isLoading = false,
  });

  final List<int> counts;
  final int? todayIndex;
  final bool isLoading;

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  static double heightFor(TextScaler scaler) =>
      26 + scaler.scale(15) * 1.2 + scaler.scale(11) * 1.2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = MonoPalette.of(context);
    final dark = theme.brightness == Brightness.dark;
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      final minTabWidth = (scaler.scale(14) * 2 + 16).clamp(48.0, 112.0);
      final scrollable = constraints.maxWidth - 8 < minTabWidth * 7;
      return DecoratedBox(
        decoration: BoxDecoration(
          color: palette.fill,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: TabBar(
            isScrollable: scrollable,
            tabAlignment: scrollable ? TabAlignment.start : TabAlignment.fill,
            dividerHeight: 0,
            indicatorSize: TabBarIndicatorSize.tab,
            indicator: BoxDecoration(
              color: dark ? const Color(0xFF636366) : Colors.white,
              borderRadius: BorderRadius.circular(9),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.3 : 0.12),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            labelColor: dark ? Colors.white : colors.primary,
            unselectedLabelColor: colors.onSurface.withValues(alpha: 0.7),
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            labelStyle: theme.textTheme.labelLarge
                ?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
            unselectedLabelStyle: theme.textTheme.labelLarge
                ?.copyWith(fontSize: 15, fontWeight: FontWeight.w400),
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            splashFactory: NoSplash.splashFactory,
            tabs: [
              for (var day = 0; day < 7; day++)
                Tab(
                  height: heightFor(scaler) - 6,
                  child: Semantics(
                    label: '星期${_weekdays[day]}'
                        '${day == todayIndex ? '，今天' : ''}'
                        '${isLoading ? '，加载中' : '，${counts[day]}部'}',
                    excludeSemantics: true,
                    child: SizedBox(
                      width: scrollable ? minTabWidth : null,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(day == todayIndex ? '今天' : '周${_weekdays[day]}'),
                          const SizedBox(height: 1),
                          Text(
                            isLoading ? '—' : '${counts[day]}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                              color: palette.secondaryLabel,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}
