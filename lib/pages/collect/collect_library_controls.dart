part of 'collect_library_view.dart';

class _CollectCategories extends StatelessWidget {
  const _CollectCategories({
    super.key,
    required this.controller,
    required this.count,
  });

  final TabController controller;
  final int Function(CollectType?) count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // Categories read as the chips of the Monogatari library: the chosen one
    // is an accent-tinted capsule.
    return TabBar(
      key: const PageStorageKey('collect-filter-strip'),
      controller: controller,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      dividerHeight: 0,
      indicatorSize: TabBarIndicatorSize.tab,
      indicatorPadding:
          const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
      indicator: ShapeDecoration(
        color: colors.primary.withValues(alpha: 0.1),
        shape: StadiumBorder(
          side: BorderSide(color: colors.primary.withValues(alpha: 0.6)),
        ),
      ),
      indicatorAnimation: TabIndicatorAnimation.elastic,
      labelColor: colors.primary,
      unselectedLabelColor: colors.onSurface.withValues(alpha: 0.75),
      labelStyle: theme.textTheme.titleSmall
          ?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
      unselectedLabelStyle: theme.textTheme.titleSmall
          ?.copyWith(fontSize: 15, fontWeight: FontWeight.w400),
      labelPadding: const EdgeInsets.symmetric(horizontal: 2),
      splashBorderRadius: BorderRadius.circular(24),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      tabs: [
        for (final type in _collectCategories)
          Tab(
            height: 44,
            child: Semantics(
              label: '${type?.label ?? '全部'}，${count(type)} 部',
              excludeSemantics: true,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 56),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: type?.label ?? '全部'),
                      if (count(type) > 0)
                        TextSpan(
                          text: ' ${count(type)}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                    ]),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CollectLayoutSwitch extends StatelessWidget {
  const _CollectLayoutSwitch({required this.value, required this.onChanged});

  final CollectLayout value;
  final ValueChanged<CollectLayout> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    // A two-segment control: grey track, raised thumb on the active layout.
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: MonoPalette.of(context).fill,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final layout in [CollectLayout.cards, CollectLayout.list])
            Semantics(
              selected: value == layout,
              inMutuallyExclusiveGroup: true,
              button: true,
              child: Tooltip(
                message: '${layout.label}布局',
                child: GestureDetector(
                  onTap: () => onChanged(layout),
                  child: AnimatedContainer(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    width: 40,
                    height: 32,
                    decoration: BoxDecoration(
                      color: value == layout
                          ? (dark ? const Color(0xFF636366) : Colors.white)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: value == layout
                          ? [
                              BoxShadow(
                                color: Colors.black
                                    .withValues(alpha: dark ? 0.3 : 0.12),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ]
                          : null,
                    ),
                    child: Icon(
                      layout == CollectLayout.list
                          ? Icons.view_list_rounded
                          : Icons.grid_view_rounded,
                      size: 20,
                      color: value == layout
                          ? (dark ? Colors.white : colors.primary)
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CollectSortMenu extends StatelessWidget {
  const _CollectSortMenu({
    required this.value,
    required this.showLabel,
    required this.onChanged,
  });

  final CollectSort value;
  final bool showLabel;
  final ValueChanged<CollectSort> onChanged;

  @override
  Widget build(BuildContext context) {
    return KazumiMenuButton(
      menuChildren: [
        for (final sort in CollectSort.values)
          KazumiMenuItem(
            selected: value == sort,
            onPressed: () => onChanged(sort),
            label: sort.label,
          ),
      ],
      builder: (context, toggle) {
        return Tooltip(
          message: '排序：${value.label}',
          child: showLabel
              ? TextButton.icon(
                  onPressed: toggle,
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.primary,
                    minimumSize: const Size(48, 40),
                    textStyle: const TextStyle(fontSize: 15),
                  ),
                  iconAlignment: IconAlignment.end,
                  icon: const Icon(Icons.unfold_more_rounded, size: 18),
                  label: Text(value.label),
                )
              : IconButton(
                  onPressed: toggle,
                  color: Theme.of(context).colorScheme.primary,
                  icon: const Icon(Icons.swap_vert_rounded),
                ),
        );
      },
    );
  }
}
