import 'package:flutter/material.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/widget/kazumi_menu.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/history/history_module.dart';

class HistoryRecordTile extends StatelessWidget {
  const HistoryRecordTile({
    super.key,
    required this.history,
    required this.onPlay,
    required this.onDetails,
    required this.onDelete,
    required this.collectType,
    required this.onChangeCollect,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.editing = false,
    this.busy = false,
  });

  final History history;
  final VoidCallback onPlay;
  final VoidCallback onDetails;
  final Future<void> Function() onDelete;
  final CollectType collectType;
  final ValueChanged<CollectType>? onChangeCollect;
  final BorderRadius borderRadius;
  final bool editing;
  final bool busy;

  String get _position {
    final progress = history.progresses[history.lastWatchEpisode]?.progress;
    if (progress == null || progress.inSeconds <= 0) return '';
    final seconds = (progress.inSeconds % 60).toString().padLeft(2, '0');
    final minutes = (progress.inMinutes % 60).toString().padLeft(2, '0');
    final position = progress.inHours > 0
        ? '${progress.inHours}:$minutes:$seconds'
        : '${progress.inMinutes}:$seconds';
    return '看到 $position';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final title = history.bangumiItem.nameCn.isEmpty
        ? history.bangumiItem.name
        : history.bangumiItem.nameCn;
    final episode = history.lastWatchEpisodeName.isEmpty
        ? '第 ${history.lastWatchEpisode} 话'
        : history.lastWatchEpisodeName;
    final source = HistoryEntryKind.normalize(history.entryKind) ==
            HistoryEntryKind.offline
        ? '缓存'
        : '在线';
    final time =
        TimeOfDay.fromDateTime(history.lastWatchTime.toLocal()).format(context);
    final image = history.bangumiItem.images['large'] ?? '';
    final position = _position;

    return Dismissible(
      key: ValueKey(history.key),
      direction:
          busy || editing ? DismissDirection.none : DismissDirection.endToStart,
      // The parent removes saved deletions; failed writes keep the row usable.
      confirmDismiss: (_) async {
        await onDelete();
        return false;
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(
            color: colors.error, borderRadius: BorderRadius.circular(12)),
        child: Icon(Icons.delete_rounded, color: colors.onError),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // Keep menu focus outside the card's InkWell to prevent stuck highlights.
            Positioned.fill(
              child: Semantics(
                button: !editing && !busy,
                label: [
                  title,
                  episode,
                  position,
                  source,
                  history.adapterName,
                  time
                ].where((text) => text.isNotEmpty).join('，'),
                child: InkWell(onTap: editing || busy ? null : onPlay),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
              child: LayoutBuilder(builder: (context, constraints) {
                final wide = constraints.maxWidth >= 600;
                final largeText =
                    MediaQuery.textScalerOf(context).scale(14) > 21;
                final coverWidth = wide ? 60.0 : 54.0;
                final content = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(episode,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 14, color: colors.onSurfaceVariant)),
                    if (position.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(position,
                          style: theme.textTheme.labelMedium?.copyWith(
                              fontSize: 12,
                              color: colors.primary,
                              fontWeight: FontWeight.w500)),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      [
                        source,
                        if (history.adapterName.isNotEmpty) history.adapterName,
                        time
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 12, color: colors.onSurfaceVariant),
                    ),
                  ],
                );
                final actions = _actions(context, wide: wide || largeText);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        ExcludeSemantics(
                          child: IgnorePointer(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: image.isEmpty
                                  ? Container(
                                      width: coverWidth,
                                      height: coverWidth * 1.4,
                                      color: colors.surfaceContainerHighest,
                                      child: Icon(Icons.movie_outlined,
                                          color: colors.onSurfaceVariant),
                                    )
                                  : NetworkImgLayer(
                                      src: image,
                                      width: coverWidth,
                                      height: coverWidth * 1.4,
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: ExcludeSemantics(
                            child: IgnorePointer(child: content),
                          ),
                        ),
                        if (!largeText) ...[
                          const SizedBox(width: 8),
                          actions,
                        ],
                      ],
                    ),
                    if (largeText) ...[
                      const SizedBox(height: 12),
                      Align(alignment: Alignment.centerRight, child: actions),
                    ],
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actions(BuildContext context, {required bool wide}) {
    final colors = Theme.of(context).colorScheme;
    if (busy) {
      return const SizedBox(
        width: 48,
        height: 48,
        child: Center(child: LoadingIndicator(size: 24)),
      );
    }
    if (editing) {
      return IconButton(
        tooltip: '删除记录',
        color: colors.error,
        onPressed: onDelete,
        icon: const Icon(Icons.remove_circle_rounded, size: 26),
      );
    }

    final buttons = [
      IconButton.filledTonal(
        tooltip: '继续播放',
        style: IconButton.styleFrom(
          minimumSize: const Size(40, 40),
          backgroundColor: colors.primary.withValues(alpha: 0.12),
          foregroundColor: colors.primary,
        ),
        onPressed: onPlay,
        icon: const Icon(Icons.play_arrow_rounded),
      ),
      KazumiMenuButton(
        menuChildren: [
          KazumiMenuItem(
            onPressed: onDetails,
            label: '番剧详情',
          ),
          SubmenuButton(
            menuChildren: [
              for (final type in CollectType.values)
                KazumiMenuItem(
                  selected: collectType == type,
                  onPressed: onChangeCollect == null
                      ? null
                      : () => onChangeCollect!(type),
                  label: type.label,
                ),
            ],
            child: Text(collectType.label),
          ),
          const Divider(),
          KazumiMenuItem(
            destructive: true,
            onPressed: onDelete,
            label: '删除记录',
          ),
        ],
        builder: (context, toggle) => IconButton(
          tooltip: '更多操作',
          color: colors.primary,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          onPressed: toggle,
          icon: const Icon(Icons.more_horiz_rounded),
        ),
      ),
    ];
    return wide
        ? Row(mainAxisSize: MainAxisSize.min, children: buttons)
        : Column(mainAxisSize: MainAxisSize.min, children: buttons);
  }
}
