import 'package:flutter/material.dart';

import 'package:kazumi/utils/theme.dart';

/// 在线播放 | RSS 播放 as a compact sliding segmented control.
class PlaybackSourceSwitch extends StatelessWidget {
  const PlaybackSourceSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String value;
  final ValueChanged<String> onChanged;

  static const _options = [('api', '在线播放'), ('rss', 'RSS 播放')];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = MonoPalette.of(context);
    final dark = theme.brightness == Brightness.dark;
    final index = _options
        .indexWhere((option) => option.$1 == value)
        .clamp(0, 1);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Container(
      height: 32,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: palette.fill,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            alignment: index == 0
                ? AlignmentDirectional.centerStart
                : AlignmentDirectional.centerEnd,
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: FractionallySizedBox(
              widthFactor: 1 / _options.length,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: dark ? palette.chip : Colors.white,
                  borderRadius: BorderRadius.circular(7),
                  boxShadow: dark
                      ? null
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.10),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (var i = 0; i < _options.length; i++)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: i == index,
                    inMutuallyExclusiveGroup: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: i == index
                          ? null
                          : () => onChanged(_options[i].$1),
                      child: Center(
                        child: Text(
                          _options[i].$2,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: i == index
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: i == index
                                ? theme.colorScheme.onSurface
                                : palette.secondaryLabel,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
