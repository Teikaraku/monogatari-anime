part of 'collect_library_view.dart';

class _CollectPosterCard extends StatelessWidget {
  const _CollectPosterCard({
    super.key,
    required this.entry,
    required this.showRating,
    required this.showStatus,
    required this.onOpen,
    required this.onChangeType,
    this.progress,
    this.onPlay,
    this.playLabel = '开始观看',
    this.onPickEpisode,
    this.hasNote = false,
    this.onEditNote,
    this.onShare,
  });

  final bool hasNote;

  final CollectedBangumi entry;
  final bool showRating;
  final bool showStatus;
  final CollectProgress? progress;
  final VoidCallback onOpen;
  final ValueChanged<CollectType>? onChangeType;
  final VoidCallback? onPlay;
  final String playLabel;
  final VoidCallback? onPickEpisode;
  final VoidCallback? onEditNote;
  final VoidCallback? onShare;

  /// One short progress phrase for the narrow poster footer.
  String? get _shortProgress {
    final progress = this.progress;
    if (progress == null) return null;
    if (progress.hasUpdate) return '更新至 ${progress.latestAired} 话';
    if (progress.watchedEpisode != null) {
      return '看到 ${progress.watchedEpisode} 话';
    }
    return null;
  }

  static const _coverRatio = 0.7;
  static bool _isCompact(double width) => width < 160;
  static double _titleHeight(TextScaler scaler, {bool compact = false}) =>
      (scaler.scale(compact ? 13 : 14) * 2.7).ceilToDouble();
  static double _detailsHeight(TextScaler scaler) =>
      (scaler.scale(12) * 1.4).ceilToDouble();
  static double _statusHeight(TextScaler scaler) =>
      (scaler.scale(11) * 1.4).ceilToDouble();
  static bool _stackCompactActions(
    double width,
    TextScaler scaler, {
    required bool showRating,
    required bool showStatus,
  }) =>
      (showRating && scaler.scale(12) * 2.5 > width - 56) ||
      (showStatus && scaler.scale(11) * 2 > width - 56);
  static double _compactActionsHeight(
    double width,
    TextScaler scaler, {
    required bool showRating,
    required bool showStatus,
  }) {
    final detailsHeight =
        (showRating ? _detailsHeight(scaler) : 0.0) +
        (showStatus ? _statusHeight(scaler) : 0.0) +
        (showRating && showStatus ? 2.0 : 0.0);
    return _stackCompactActions(
          width,
          scaler,
          showRating: showRating,
          showStatus: showStatus,
        )
        ? detailsHeight + 48
        : detailsHeight.clamp(48.0, double.infinity);
  }

  static double extent(
    double width,
    TextScaler scaler, {
    required bool showRating,
    required bool showStatus,
  }) {
    final footerHeight = _isCompact(width)
        ? 12 +
              _titleHeight(scaler, compact: true) +
              _compactActionsHeight(
                width,
                scaler,
                showRating: showRating,
                showStatus: showStatus,
              )
        : 16 +
              (_titleHeight(scaler) +
                      (showRating || showStatus
                          ? 4 + _detailsHeight(scaler)
                          : 0))
                  .clamp(48.0, double.infinity);
    return width / _coverRatio + footerHeight;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final scaler = MediaQuery.textScalerOf(context);
    final item = entry.bangumiItem;
    final title = CollectLibraryQuery.titleOf(entry);
    final year = DateTime.tryParse(item.airDate)?.year;
    final type = CollectType.fromValue(entry.type);
    final hasRating = showRating && item.ratingScore > 0;
    final showDetails = showStatus || showRating;
    final shortProgress = _shortProgress;
    final hasUpdate = progress?.hasUpdate ?? false;

    Widget detailLine(String value, {bool status = false}) => SizedBox(
      height: status ? _statusHeight(scaler) : _detailsHeight(scaler),
      child: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          fontSize: status ? 11 : 12,
          height: 1.4,
          color: colors.onSurfaceVariant,
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = _isCompact(constraints.maxWidth);
        final titleBlock = ExcludeSemantics(
          child: SizedBox(
            height: _titleHeight(scaler, compact: compact),
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: compact ? 13 : 14,
                height: 1.35,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        );
        final detailsBlock = ExcludeSemantics(
          child: compact
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showRating)
                      detailLine(
                        shortProgress ??
                            (hasRating
                                ? item.ratingScore.toStringAsFixed(1)
                                : ''),
                      ),
                    if (showStatus) ...[
                      if (showRating) const SizedBox(height: 2),
                      detailLine(type.label, status: true),
                    ],
                  ],
                )
              : detailLine(
                  [
                    if (shortProgress != null)
                      shortProgress
                    else if (hasRating)
                      '${item.ratingScore.toStringAsFixed(1)} 分',
                    if (showStatus) type.label,
                  ].join(' · '),
                ),
        );
        final menu = _CollectEntryMenu(
          entry: entry,
          onChanged: onChangeType,
          onPlay: onPlay,
          playLabel: playLabel,
          onPickEpisode: onPickEpisode,
          hasNote: hasNote,
          onEditNote: onEditNote,
          onShare: onShare,
        );
        final footer = compact
            ? Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: titleBlock,
                    ),
                    SizedBox(
                      height: _compactActionsHeight(
                        constraints.maxWidth,
                        scaler,
                        showRating: showRating,
                        showStatus: showStatus,
                      ),
                      child:
                          _stackCompactActions(
                            constraints.maxWidth,
                            scaler,
                            showRating: showRating,
                            showStatus: showStatus,
                          )
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                  ),
                                  child: detailsBlock,
                                ),
                                Align(
                                  alignment: AlignmentDirectional.centerEnd,
                                  child: menu,
                                ),
                              ],
                            )
                          : Padding(
                              padding: const EdgeInsetsDirectional.only(
                                start: 2,
                              ),
                              child: Row(
                                children: [
                                  Expanded(child: detailsBlock),
                                  menu,
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              )
            : Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(2, 7, 0, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          titleBlock,
                          if (showDetails) ...[
                            const SizedBox(height: 4),
                            detailsBlock,
                          ],
                        ],
                      ),
                    ),
                    menu,
                  ],
                ),
              );

        return Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: Semantics(
            button: true,
            label: [
              title,
              type.label,
              if (hasUpdate) '有更新',
              ?shortProgress,
              if (year != null) '$year 年',
              if (hasRating) '${item.ratingScore.toStringAsFixed(1)} 分',
            ].join('，'),
            child: InkWell(
              onTap: onOpen,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ExcludeSemantics(
                    child: AspectRatio(
                      aspectRatio: _coverRatio,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _CollectCover(
                            item: item,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          if (hasUpdate)
                            const PositionedDirectional(
                              top: 6,
                              start: 6,
                              child: _UpdateBadge(onCover: true),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(child: footer),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CollectListTile extends StatelessWidget {
  const _CollectListTile({
    super.key,
    required this.entry,
    required this.showRating,
    required this.showStatus,
    required this.onOpen,
    required this.onChangeType,
    this.progress,
    this.onPlay,
    this.playLabel = '开始观看',
    this.onPickEpisode,
    this.note,
    this.onEditNote,
    this.onShare,
  });

  /// The user's own line about the show, shown under the metadata.
  final String? note;

  final CollectedBangumi entry;
  final bool showRating;

  /// Shows the 追番 status, for the 全部 category.
  final bool showStatus;
  final CollectProgress? progress;
  final VoidCallback onOpen;
  final ValueChanged<CollectType>? onChangeType;
  final VoidCallback? onPlay;
  final String playLabel;
  final VoidCallback? onPickEpisode;
  final VoidCallback? onEditNote;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final item = entry.bangumiItem;
    final title = CollectLibraryQuery.titleOf(entry);
    final airDate = DateTime.tryParse(item.airDate);
    final progressLabel = progress?.progressLabel ?? '';
    final schedule = progress?.scheduleLabel;
    final hasUpdate = progress?.hasUpdate ?? false;
    final metadata = [
      if (showStatus) CollectType.fromValue(entry.type).label,
      if (schedule != null)
        schedule
      else if (airDate != null)
        '${airDate.year} 年',
      if (showRating && item.ratingScore > 0)
        '${item.ratingScore.toStringAsFixed(1)} 分',
    ];

    return Material(
      color: colors.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Isolate the buttons from card navigation.
          Positioned.fill(
            child: Semantics(
              button: true,
              label: [
                title,
                if (hasUpdate) '有更新',
                if (progressLabel.isNotEmpty) progressLabel,
                ...metadata,
              ].join('，'),
              child: InkWell(onTap: onOpen),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ExcludeSemantics(
                    child: IgnorePointer(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: 88,
                          height: 128,
                          child: _CollectCover(
                            item: item,
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: ExcludeSemantics(
                                child: IgnorePointer(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Text(
                                      title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            height: 1.35,
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            _CollectEntryMenu(
                              entry: entry,
                              onChanged: onChangeType,
                              hasNote: note != null,
                              onEditNote: onEditNote,
                              onShare: onShare,
                            ),
                          ],
                        ),
                        ExcludeSemantics(
                          child: IgnorePointer(
                            child: Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (progressLabel.isNotEmpty || hasUpdate)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Row(
                                        children: [
                                          if (hasUpdate) ...[
                                            const _UpdateBadge(),
                                            const SizedBox(width: 6),
                                          ],
                                          Flexible(
                                            child: Text(
                                              progressLabel,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w500,
                                                    color: colors.onSurface,
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (metadata.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(
                                        metadata.join(' · '),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontSize: 12,
                                              color: colors.onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                  if (note != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: _NoteLine(note: note!),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const Spacer(),
                        const SizedBox(height: 10),
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 4,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (onPickEpisode != null)
                                  TextButton(
                                    onPressed: onPickEpisode,
                                    style: TextButton.styleFrom(
                                      foregroundColor: colors.primary,
                                      minimumSize: const Size(56, 36),
                                      textStyle: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    child: const Text('选集'),
                                  ),
                                if (onPlay != null)
                                  TextButton.icon(
                                    onPressed: onPlay,
                                    style: TextButton.styleFrom(
                                      backgroundColor: colors.primary,
                                      foregroundColor: colors.onPrimary,
                                      shape: const StadiumBorder(),
                                      visualDensity: VisualDensity.standard,
                                      tapTargetSize:
                                          MaterialTapTargetSize.padded,
                                      minimumSize: const Size(0, 36),
                                      padding:
                                          const EdgeInsetsDirectional.fromSTEB(
                                            12,
                                            0,
                                            16,
                                            0,
                                          ),
                                      textStyle: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    icon: const Icon(
                                      Icons.play_arrow_rounded,
                                      size: 20,
                                    ),
                                    label: Text(playLabel),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CollectCover extends StatelessWidget {
  const _CollectCover({required this.item, this.borderRadius});
  final BangumiItem item;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Hero(
      tag: item.id,
      transitionOnUserGestures: true,
      flightShuttleBuilder: NetworkImgLayer.heroFlightShuttleBuilder,
      child: NetworkImgLayer(
        src: item.images['large'] ?? item.images['common'] ?? '',
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        borderRadius: borderRadius,
      ),
    ),
  );
}

class _UpdateBadge extends StatelessWidget {
  const _UpdateBadge({this.onCover = false});

  /// Solid on covers, where a tint would not read over artwork.
  final bool onCover;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: onCover
            ? colors.primary
            : colors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Text(
          onCover ? '更新' : '有更新',
          style: TextStyle(
            fontSize: 11,
            height: 1.35,
            fontWeight: FontWeight.w600,
            color: onCover ? colors.onPrimary : colors.primary,
          ),
        ),
      ),
    );
  }
}

class _CollectEntryMenu extends StatelessWidget {
  const _CollectEntryMenu({
    required this.entry,
    required this.onChanged,
    this.onPlay,
    this.playLabel = '开始观看',
    this.onPickEpisode,
    this.hasNote = false,
    this.onEditNote,
    this.onShare,
  });

  final bool hasNote;
  final CollectedBangumi entry;
  final ValueChanged<CollectType>? onChanged;

  /// Offered first in the poster menu; the list tile has its own buttons.
  final VoidCallback? onPlay;
  final String playLabel;
  final VoidCallback? onPickEpisode;
  final VoidCallback? onEditNote;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final type = CollectType.fromValue(entry.type);
    final title = CollectLibraryQuery.titleOf(entry);
    return KazumiMenuButton(
      enabled:
          onChanged != null ||
          onPlay != null ||
          onPickEpisode != null ||
          onEditNote != null ||
          onShare != null,
      menuChildren: [
        if (onPlay != null) KazumiMenuItem(onPressed: onPlay, label: playLabel),
        if (onPickEpisode != null)
          KazumiMenuItem(onPressed: onPickEpisode, label: '选集'),
        if (onPlay != null || onPickEpisode != null)
          const Divider(indent: 16, endIndent: 16),
        if (onEditNote != null)
          KazumiMenuItem(
            onPressed: onEditNote,
            label: hasNote ? '编辑备注' : '写备注',
          ),
        if (onShare != null) KazumiMenuItem(onPressed: onShare, label: '分享海报'),
        if (onEditNote != null || onShare != null)
          const Divider(indent: 16, endIndent: 16),
        for (final status in CollectType.values.where(
          (type) => type.isCollected,
        ))
          KazumiMenuItem(
            selected: status == type,
            onPressed: onChanged == null || status == type
                ? null
                : () => onChanged!(status),
            label: status.label,
          ),
        const Divider(indent: 16, endIndent: 16),
        KazumiMenuItem(
          onPressed: onChanged == null
              ? null
              : () => onChanged!(CollectType.none),
          label: '取消收藏',
          destructive: true,
        ),
      ],
      builder: (context, toggle) {
        return IconButton(
          tooltip: '管理《$title》 · ${type.label}',
          onPressed: toggle,
          style: IconButton.styleFrom(
            foregroundColor: colors.primary,
            minimumSize: const Size(40, 40),
            visualDensity: VisualDensity.standard,
          ),
          icon: const Icon(Icons.more_horiz_rounded, size: 20),
        );
      },
    );
  }
}

class _NoteLine extends StatelessWidget {
  const _NoteLine({required this.note});

  final String note;

  @override
  Widget build(BuildContext context) {
    final palette = MonoPalette.of(context);
    return Row(
      children: [
        Icon(Icons.edit_note_rounded, size: 15, color: palette.secondaryLabel),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            note,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: palette.secondaryLabel),
          ),
        ),
      ],
    );
  }
}
