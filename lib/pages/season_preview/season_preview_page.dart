import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/broadcast_slot.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/season_preview/season_preview_deck.dart';
import 'package:kazumi/request/apis/airtime_api.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/anime_season.dart';

const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

String _coverUrl(BangumiItem item) => ['large', 'common', 'medium']
    .map((size) => item.images[size]?.trim() ?? '')
    .firstWhere((url) => url.isNotEmpty, orElse: () => '');

/// 新番速览: swipe right for 想看, left to skip, or tap 在看.
class SeasonPreviewPage extends StatefulWidget {
  const SeasonPreviewPage({super.key});

  @override
  State<SeasonPreviewPage> createState() => _SeasonPreviewPageState();
}

class _SeasonPreviewPageState extends State<SeasonPreviewPage>
    with SingleTickerProviderStateMixin {
  final _store = SeasonPreviewStore.instance;
  final _collect = inject<CollectController>();
  final DateTime _now = DateTime.now();
  late final String _season = SeasonPreviewStore.seasonKey(_now);
  late final _fling = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  /// The top card's offset; only the cards' transforms listen to it.
  final _drag = ValueNotifier<Offset>(Offset.zero);
  Animation<Offset>? _flight;
  SeasonPreviewDeck? _deck;
  Map<int, BroadcastSlot> _slots = const {};
  Object? _error;
  bool _committing = false;

  @override
  void initState() {
    super.initState();
    _fling.addListener(() {
      final flight = _flight;
      if (flight != null) _drag.value = flight.value;
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _fling.dispose();
    _drag.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _deck = null;
    });
    try {
      final slots = AirtimeApi.load().catchError((Object _) {
        return const <int, BroadcastSlot>{};
      });
      final shows = await _store.load(_now);
      final collected = {
        for (final show in shows)
          if (_collect.getCollectType(show) != CollectType.none.value) show.id,
      };
      final deck = SeasonPreviewDeck(
        SeasonPreviewDeck.arrange(
          shows,
          exclude: {...collected, ..._store.seen(_season)},
        ),
      );
      _slots = await slots;
      if (mounted) setState(() => _deck = deck);
    } catch (error) {
      KazumiLogger().w('SeasonPreview: loading failed', error: error);
      if (mounted) setState(() => _error = error);
    }
  }

  void _warmCovers(BuildContext context, double width) {
    final deck = _deck;
    if (deck == null) return;
    final pixels = (width * MediaQuery.devicePixelRatioOf(context)).round();
    for (final item in [?deck.next, ...deck.upcoming(2)]) {
      final url = _coverUrl(item);
      if (url.isEmpty) continue;
      unawaited(
        precacheImage(
          ResizeImage(CachedNetworkImageProvider(url), width: pixels),
          context,
        ).catchError((Object _) {}),
      );
    }
  }

  /// Flies the top card out, then records the decision.
  Future<void> _decide(PreviewDecision decision, Size area) async {
    final deck = _deck;
    final item = deck?.current;
    if (deck == null || item == null || _committing) return;
    _committing = true;
    final target = switch (decision) {
      PreviewDecision.skip => Offset(-area.width * 1.4, _drag.value.dy),
      PreviewDecision.planToWatch => Offset(area.width * 1.4, _drag.value.dy),
      PreviewDecision.watching => Offset(_drag.value.dx, -area.height * 1.2),
    };
    _flight = Tween(
      begin: _drag.value,
      end: target,
    ).animate(CurvedAnimation(parent: _fling, curve: Curves.easeIn));
    await _fling.forward(from: 0);
    _flight = null;
    _drag.value = Offset.zero;
    setState(() => deck.decide(decision));
    _committing = false;
    unawaited(_store.setSeen(_season, item.id, true));
    if (decision.collectType != CollectType.none) {
      try {
        await _collect.addCollect(item, type: decision.collectType.value);
      } catch (_) {
        KazumiDialog.showToast(message: '加入追番失败，请稍后重试');
      }
    }
  }

  Future<void> _springBack() async {
    _flight = Tween(
      begin: _drag.value,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _fling, curve: Curves.easeOutBack));
    await _fling.forward(from: 0);
    _flight = null;
  }

  Future<void> _undo() async {
    final deck = _deck;
    if (deck == null || _committing) return;
    final last = deck.undo();
    if (last == null) return;
    final (item, decision) = last;
    setState(() {});
    unawaited(_store.setSeen(_season, item.id, false));
    if (decision.collectType != CollectType.none) {
      try {
        await _collect.addCollect(item, type: CollectType.none.value);
      } catch (_) {
        KazumiDialog.showToast(message: '撤销失败，请到追番中修改');
      }
    }
  }

  void _onPanEnd(DragEndDetails details, Size area) {
    final offset = _drag.value;
    final velocity = details.velocity.pixelsPerSecond;
    if (offset.dx > area.width * 0.28 || velocity.dx > 900) {
      unawaited(_decide(PreviewDecision.planToWatch, area));
    } else if (offset.dx < -area.width * 0.28 || velocity.dx < -900) {
      unawaited(_decide(PreviewDecision.skip, area));
    } else if (offset.dy < -area.height * 0.22 || velocity.dy < -900) {
      unawaited(_decide(PreviewDecision.watching, area));
    } else {
      unawaited(_springBack());
    }
  }

  @override
  Widget build(BuildContext context) {
    final deck = _deck;
    return Scaffold(
      appBar: SysAppBar(
        title: Text(AnimeSeason(_now).toString()),
        actions: [
          IconButton(
            tooltip: '撤销',
            onPressed: deck != null && deck.canUndo ? _undo : null,
            icon: const Icon(Icons.undo_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _error != null
            ? GeneralEmptyState(
                icon: Icons.cloud_off_rounded,
                title: '新番加载失败',
                actions: [
                  FilledButton(onPressed: _load, child: const Text('重试')),
                ],
              )
            : deck == null
            ? const Center(child: LoadingIndicator())
            : deck.isDone
            ? GeneralEmptyState(
                icon: Icons.celebration_rounded,
                title: '本季新番已经看完了',
                actions: [
                  FilledButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('返回'),
                  ),
                ],
              )
            : LayoutBuilder(builder: _deckView),
      ),
    );
  }

  Widget _deckView(BuildContext context, BoxConstraints constraints) {
    final deck = _deck!;
    final area = constraints.biggest;
    final width = math.min(area.width - 40, 400.0);
    final height = math.min(area.height - 140, width * 1.5);
    final cardSize = Size(width, height);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _warmCovers(context, width);
    });
    final next = deck.next;
    final current = deck.current!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 12),
          child: Text(
            '还有 ${deck.remaining} 部',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: Center(
            child: SizedBox.fromSize(
              size: cardSize,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (next != null)
                    ValueListenableBuilder<Offset>(
                      valueListenable: _drag,
                      // The card below grows as the top one leaves.
                      builder: (context, offset, child) {
                        final progress = (offset.distance / (width * 0.6))
                            .clamp(0.0, 1.0);
                        return Transform.scale(
                          scale: 0.94 + 0.06 * progress,
                          child: child,
                        );
                      },
                      child: RepaintBoundary(
                        key: ValueKey('preview-${next.id}'),
                        child: _PreviewCard(
                          item: next,
                          slot: _slots[next.id],
                          size: cardSize,
                        ),
                      ),
                    ),
                  GestureDetector(
                    key: ValueKey('preview-top-${current.id}'),
                    onPanUpdate: (details) {
                      if (!_committing) _drag.value += details.delta;
                    },
                    onPanEnd: (details) => _onPanEnd(details, area),
                    onTap: () =>
                        context.pushNamed('/info/', arguments: current),
                    child: ValueListenableBuilder<Offset>(
                      valueListenable: _drag,
                      builder: (context, offset, child) => Transform.translate(
                        offset: offset,
                        child: Transform.rotate(
                          angle: offset.dx / width * 0.22,
                          child: Stack(
                            children: [
                              child!,
                              _Stamp(
                                label: '想看',
                                alignment: Alignment.topLeft,
                                opacity: (offset.dx / (width * 0.28)).clamp(
                                  0.0,
                                  1.0,
                                ),
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              _Stamp(
                                label: '跳过',
                                alignment: Alignment.topRight,
                                opacity: (-offset.dx / (width * 0.28)).clamp(
                                  0.0,
                                  1.0,
                                ),
                                color: Colors.white,
                              ),
                              _Stamp(
                                label: '在看',
                                alignment: Alignment.bottomCenter,
                                opacity: (-offset.dy / (height * 0.22)).clamp(
                                  0.0,
                                  1.0,
                                ),
                                color: const Color(0xFF34C759),
                              ),
                            ],
                          ),
                        ),
                      ),
                      child: RepaintBoundary(
                        child: _PreviewCard(
                          item: current,
                          slot: _slots[current.id],
                          size: cardSize,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _RoundButton(
                tooltip: '跳过',
                icon: Icons.close_rounded,
                onPressed: () => _decide(PreviewDecision.skip, area),
              ),
              const SizedBox(width: 20),
              _RoundButton(
                tooltip: '在看',
                icon: Icons.play_arrow_rounded,
                color: const Color(0xFF34C759),
                onPressed: () => _decide(PreviewDecision.watching, area),
              ),
              const SizedBox(width: 20),
              _RoundButton(
                tooltip: '想看',
                icon: Icons.favorite_rounded,
                color: Theme.of(context).colorScheme.primary,
                large: true,
                onPressed: () => _decide(PreviewDecision.planToWatch, area),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.item, required this.size, this.slot});

  final BangumiItem item;
  final Size size;
  final BroadcastSlot? slot;

  @override
  Widget build(BuildContext context) {
    final url = _coverUrl(item);
    final pixels = (size.width * MediaQuery.devicePixelRatioOf(context))
        .round();
    final title = item.nameCn.isNotEmpty ? item.nameCn : item.name;
    final original = item.nameCn.isNotEmpty && item.name != item.nameCn
        ? item.name
        : null;
    final airDate = DateTime.tryParse(item.airDate);
    final slot = this.slot;
    final facts = [
      if (item.ratingScore > 0) '★ ${item.ratingScore.toStringAsFixed(1)}',
      if (slot != null)
        '每周${_weekdays[slot.localWeekday - 1]} ${slot.localTimeLabel}'
      else if (airDate != null)
        '${airDate.month} 月 ${airDate.day} 日开播',
    ];
    return SizedBox.fromSize(
      size: size,
      child: Material(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        elevation: 6,
        shadowColor: Colors.black54,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url.isNotEmpty)
              Image(
                image: ResizeImage(
                  CachedNetworkImageProvider(url),
                  width: pixels,
                ),
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.45, 1],
                  colors: [Color(0x00000000), Color(0xE6000000)],
                ),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 20,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      height: 1.3,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (original != null)
                    Text(
                      original,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xB3FFFFFF),
                        fontSize: 13,
                      ),
                    ),
                  if (facts.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      facts.join(' · '),
                      style: const TextStyle(
                        color: Color(0xE6FFFFFF),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  if (item.tags.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final tag in item.tags.take(3))
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0x33FFFFFF),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              tag.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                  if (item.summary.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      item.summary.trim(),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xCCFFFFFF),
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stamp extends StatelessWidget {
  const _Stamp({
    required this.label,
    required this.alignment,
    required this.opacity,
    required this.color,
  });

  final String label;
  final Alignment alignment;
  final double opacity;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (opacity <= 0) return const SizedBox.shrink();
    return Positioned.fill(
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Opacity(
            opacity: opacity,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: color, width: 3),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
    this.large = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Color? color;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tint = color ?? colors.onSurfaceVariant;
    final size = large ? 68.0 : 56.0;
    return IconButton.filled(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: large ? 32 : 26,
      style: IconButton.styleFrom(
        fixedSize: Size.square(size),
        backgroundColor: Color.alphaBlend(
          tint.withValues(alpha: 0.14),
          colors.surfaceContainer,
        ),
        foregroundColor: tint,
      ),
      icon: Icon(icon),
    );
  }
}
