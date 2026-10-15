import 'package:flutter/material.dart';

import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/modules/bangumi/airing_summary.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/request/apis/main_episode_cache.dart';
import 'package:kazumi/utils/theme.dart';

/// Marks episodes (第 N 话) as watched or not by hand.
typedef EpisodeMarkCallback =
    Future<void> Function(List<int> episodes, bool watched);

/// 选集播放: the main episodes of a show from Bangumi. Picking one plays it
/// from its start; watched episodes and the last one played are marked. A
/// long press (or secondary click) marks episodes by hand.
class EpisodePickerSheet extends StatefulWidget {
  const EpisodePickerSheet({
    super.key,
    required this.bangumiItem,
    required this.watched,
    required this.onPlay,
    this.onDetails,
    this.onMark,
    this.lastWatched,
  });

  final BangumiItem bangumiItem;

  /// Episode numbers (第 N 话) counted as watched.
  final Set<int> watched;
  final int? lastWatched;
  final ValueChanged<int> onPlay;

  /// Shows 条目详情 when given.
  final VoidCallback? onDetails;
  final EpisodeMarkCallback? onMark;

  @override
  State<EpisodePickerSheet> createState() => _EpisodePickerSheetState();
}

class _EpisodePickerSheetState extends State<EpisodePickerSheet> {
  static const double _minCell = 64;
  static const double _cellHeight = 48;
  static const double _gap = 10;
  static const double _sidePadding = 20;

  late Future<List<EpisodeInfo>> _episodes =
      MainEpisodeCache.get(widget.bangumiItem.id);
  ScrollController? _scroll;

  /// Updated at once when marking; the store writes in the background.
  late final Set<int> _watched = {...widget.watched};

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  void _retry() => setState(() {
        _episodes = MainEpisodeCache.get(widget.bangumiItem.id);
      });

  void _pick(int number) {
    Navigator.of(context).pop();
    widget.onPlay(number);
  }

  Future<void> _showMarkMenu(int number, Offset position) async {
    final onMark = widget.onMark;
    if (onMark == null) return;
    final watched = _watched.contains(number);
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<_MarkAction>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: watched ? _MarkAction.unwatched : _MarkAction.watched,
          child: Text(watched ? '标记为没看过' : '标记为看过'),
        ),
        if (number > 1)
          PopupMenuItem(
            value: _MarkAction.upTo,
            child: Text('第 1–$number 话标记为看过'),
          ),
      ],
    );
    if (action == null || !mounted) return;
    final episodes = action == _MarkAction.upTo
        ? [for (var i = 1; i <= number; i++) i]
        : [number];
    final markWatched = action != _MarkAction.unwatched;
    setState(() {
      if (markWatched) {
        _watched.addAll(episodes);
      } else {
        _watched.removeAll(episodes);
      }
    });
    await onMark(episodes, markWatched);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.bangumiItem;
    final title = item.nameCn.isNotEmpty ? item.nameCn : item.name;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MaterialBottomSheetHeader(
          title: '选集播放',
          description: title,
          onClose: () => Navigator.of(context).pop(),
        ),
        Flexible(
          child: FutureBuilder<List<EpisodeInfo>>(
            future: _episodes,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 160,
                  child: Center(child: LoadingIndicator()),
                );
              }
              if (snapshot.hasError) {
                return _Message(
                  text: '分集信息加载失败',
                  action: TextButton(onPressed: _retry, child: const Text('重试')),
                );
              }
              final summary = AiringSummary.of(snapshot.data ?? const [],
                  today: DateTime.now());
              final numbered = [
                for (final episode in summary.episodes)
                  if (episode.displayNumber > 0 &&
                      episode.displayNumber == episode.displayNumber.toInt())
                    episode,
              ];
              if (numbered.isEmpty) {
                return const _Message(text: '暂无分集信息');
              }
              return _grid(numbered);
            },
          ),
        ),
        if (widget.onDetails != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onDetails!();
                },
                child: const Text('条目详情'),
              ),
            ),
          )
        else
          SizedBox(height: 8 + MediaQuery.paddingOf(context).bottom),
      ],
    );
  }

  Widget _grid(List<EpisodeInfo> episodes) {
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);
    final focus = widget.lastWatched ?? 1;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth - _sidePadding * 2;
      final columns =
          ((width + _gap) / (_minCell + _gap)).floor().clamp(4, 8);
      // Open near the last episode played, for long-running shows.
      final focusIndex = episodes.indexWhere(
          (episode) => episode.displayNumber.toInt() == focus);
      final focusRow = focusIndex < 0 ? 0 : focusIndex ~/ columns;
      _scroll ??= ScrollController(
        initialScrollOffset:
            (focusRow - 1).clamp(0, 1 << 20) * (_cellHeight + _gap),
      );
      return GridView.builder(
        controller: _scroll,
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(_sidePadding, 4, _sidePadding, 8),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: _gap,
          crossAxisSpacing: _gap,
          mainAxisExtent: _cellHeight,
        ),
        itemCount: episodes.length,
        itemBuilder: (context, index) {
          final episode = episodes[index];
          final number = episode.displayNumber.toInt();
          final airDay = episode.airDay;
          return _EpisodeCell(
            number: number,
            current: number == widget.lastWatched,
            watched: _watched.contains(number),
            aired: airDay == null || !airDay.isAfter(day),
            onTap: () => _pick(number),
            onMark: widget.onMark == null
                ? null
                : (position) => _showMarkMenu(number, position),
          );
        },
      );
    });
  }
}

enum _MarkAction { watched, unwatched, upTo }

class _EpisodeCell extends StatelessWidget {
  const _EpisodeCell({
    required this.number,
    required this.current,
    required this.watched,
    required this.aired,
    required this.onTap,
    this.onMark,
  });

  final int number;

  /// The episode played last.
  final bool current;
  final bool watched;

  /// Not yet broadcast episodes cannot be picked.
  final bool aired;
  final VoidCallback onTap;

  /// Opens the mark menu at a global position.
  final ValueChanged<Offset>? onMark;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = MonoPalette.of(context);
    final background = !aired
        ? Colors.transparent
        : current
            ? colors.primary
            : watched
                ? colors.primary.withValues(alpha: 0.12)
                : palette.sheetGroup;
    final foreground = !aired
        ? palette.tertiaryLabel
        : current
            ? colors.onPrimary
            : watched
                ? colors.primary
                : colors.onSurface;
    return Semantics(
      button: true,
      enabled: aired,
      selected: current,
      label: '第 $number 话'
          '${current ? '，上次看到' : watched ? '，看过' : ''}'
          '${aired ? '' : '，未播出'}',
      excludeSemantics: true,
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: aired
              ? BorderSide.none
              : BorderSide(color: palette.hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: aired ? onTap : null,
          onLongPress: onMark == null
              ? null
              : () {
                  final box = context.findRenderObject() as RenderBox;
                  onMark!(box.localToGlobal(box.size.center(Offset.zero)));
                },
          onSecondaryTapUp: onMark == null
              ? null
              : (details) => onMark!(details.globalPosition),
          child: Center(
            child: Text(
              number < 10 ? '0$number' : '$number',
              style: TextStyle(
                fontSize: 16,
                fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                color: foreground,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: TextStyle(
                fontSize: 15, color: MonoPalette.of(context).secondaryLabel),
          ),
          if (action != null) ...[const SizedBox(height: 8), action!],
        ],
      ),
    );
  }
}
