import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/mono_chip.dart';
import 'package:kazumi/utils/theme.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/history/history_list_query.dart';

class HistoryListView extends StatefulWidget {
  const HistoryListView({
    super.key,
    required this.entries,
    required this.itemBuilder,
    this.editing = false,
  });

  final List<History> entries;
  final bool editing;
  final Widget Function(History history, BorderRadius borderRadius) itemBuilder;

  @override
  State<HistoryListView> createState() => _HistoryListViewState();
}

class _HistoryListViewState extends State<HistoryListView> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _scrollController = ScrollController();
  HistorySourceFilter _source = HistorySourceFilter.all;
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _updateFilters(VoidCallback update) {
    setState(update);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  void _clearSearch() {
    _searchController.clear();
    _updateFilters(() => _query = '');
  }

  void _resetFilters() {
    _searchController.clear();
    _updateFilters(() {
      _query = '';
      _source = HistorySourceFilter.all;
    });
    _searchFocus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final groups =
        groupHistoryEntries(widget.entries, query: _query, source: _source);
    // Separate sliver delegates eagerly lay out the first card of every date.
    final rows = <_HistoryListRow>[
      for (final group in groups) ...[
        _HistoryListRow(group),
        for (var index = 0; index < group.entries.length; index++)
          _HistoryListRow(group, entryIndex: index),
      ],
    ];
    final rowIndices = <Key, int>{
      for (var index = 0; index < rows.length; index++) rows[index].key: index,
    };
    final count =
        groups.fold<int>(0, (total, group) => total + group.entries.length);
    final filtered =
        _query.trim().isNotEmpty || _source != HistorySourceFilter.all;
    final now = DateTime.now();

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _searchFocus.requestFocus,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _searchFocus.requestFocus,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          _clearSearch();
          _searchFocus.unfocus();
        },
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(builder: (context, constraints) {
          final contentWidth = constraints.maxWidth.clamp(0.0, 960.0);
          // Preserve full-width scrolling while centering the content.
          final inset = (constraints.maxWidth - contentWidth) / 2 +
              (constraints.maxWidth < 600 ? 16.0 : 24.0);
          return Scrollbar(
            controller: _scrollController,
            child: CustomScrollView(
              key: const PageStorageKey('history-list'),
              controller: _scrollController,
              scrollBehavior:
                  ScrollConfiguration.of(context).copyWith(scrollbars: false),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                if (widget.entries.isNotEmpty || filtered)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(inset, 4, inset, 0),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: _searchController,
                            focusNode: _searchFocus,
                            textInputAction: TextInputAction.search,
                            decoration: InputDecoration(
                              hintText: '搜索番剧、别名或来源',
                              prefixIcon: const Icon(Icons.search_rounded),
                              suffixIcon: _query.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: '清除搜索',
                                      onPressed: _clearSearch,
                                      icon: const Icon(Icons.cancel_rounded,
                                          size: 18),
                                    ),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 12),
                            ),
                            onChanged: (value) =>
                                _updateFilters(() => _query = value),
                            onSubmitted: (_) => _searchFocus.unfocus(),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final source in HistorySourceFilter.values)
                                _filter(source),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              widget.editing
                                  ? '共 $count 条记录 · 点按删除按钮移除'
                                  : filtered
                                      ? '找到 $count 条记录 · 最近观看优先'
                                      : '共 $count 条记录 · 最近观看优先',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 13, color: colors.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (groups.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _emptyState(filtered),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(inset, 0, inset,
                        24 + MediaQuery.paddingOf(context).bottom),
                    sliver: SliverList.builder(
                      itemCount: rows.length,
                      findChildIndexCallback: (key) => rowIndices[key],
                      itemBuilder: (context, index) =>
                          _buildRow(context, rows[index], now),
                    ),
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildRow(BuildContext context, _HistoryListRow row, DateTime now) {
    final group = row.group;
    final entryIndex = row.entryIndex;
    if (entryIndex == null) {
      final theme = Theme.of(context);
      return Padding(
        key: row.key,
        padding: const EdgeInsets.fromLTRB(4, 22, 4, 4),
        child: Semantics(
          header: true,
          child: Row(
            children: [
              Expanded(
                child: Text(group.label(now),
                    style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 20, fontWeight: FontWeight.w700)),
              ),
              Text('${group.entries.length} 条',
                  style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      );
    }
    final shape = BorderRadius.vertical(
      top: Radius.circular(entryIndex == 0 ? 24 : 4),
      bottom: Radius.circular(entryIndex == group.entries.length - 1 ? 24 : 4),
    );
    final last = entryIndex == group.entries.length - 1;
    return Column(
      key: row.key,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.itemBuilder(group.entries[entryIndex], shape),
        if (!last)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 72),
            child: Container(
                height: 0.5, color: MonoPalette.of(context).hairline),
          ),
      ],
    );
  }

  Widget _filter(HistorySourceFilter source) => MonoChip(
        label: source.label,
        selected: _source == source,
        onTap: () => _updateFilters(() => _source = source),
      );

  Widget _emptyState(bool filtered) {
    return GeneralEmptyState(
      icon: filtered ? Icons.search_off_rounded : Icons.history_rounded,
      title: filtered ? '没有找到相关记录' : '还没有观看记录',
      actions: [
        if (filtered)
          StateActionButton.tonal(
            onPressed: _resetFilters,
            text: '查看全部记录',
          ),
      ],
    );
  }
}

class _HistoryListRow {
  const _HistoryListRow(this.group, {this.entryIndex});

  final HistoryDateGroup group;
  final int? entryIndex;

  Key get key {
    final index = entryIndex;
    return index == null
        ? ValueKey(group.date)
        : ValueKey(group.entries[index].key);
  }
}
