import 'package:flutter/material.dart';

/// The symbol above an empty, error or progress message. Like the empty pages
/// of the Monogatari apps it is a plain glyph, not a filled badge;
/// [backgroundColor] is kept for callers and only used as a faint halo.
class StateIconBadge extends StatelessWidget {
  const StateIconBadge({
    super.key,
    required this.icon,
    required this.size,
    required this.iconSize,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final IconData icon;
  final double size;
  final double iconSize;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox.square(
          dimension: size,
          child: Icon(icon, size: size * 0.72, color: foregroundColor),
        ),
      );
}

class StateActionButton extends StatelessWidget {
  const StateActionButton({
    super.key,
    required this.onPressed,
    required this.text,
    this.icon,
    this.reserveText,
  }) : _tonal = false;

  const StateActionButton.tonal({
    super.key,
    required this.onPressed,
    required this.text,
    this.icon,
    this.reserveText,
  }) : _tonal = true;

  final VoidCallback? onPressed;
  final String text;
  final IconData? icon;

  /// Reserves label space for a longer status without changing button size.
  final String? reserveText;
  final bool _tonal;

  static ButtonStyle styleOf(BuildContext context) {
    return const ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(64, 44)),
      padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 20, vertical: 10)),
      shape: WidgetStatePropertyAll(StadiumBorder()),
      textStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final button = _tonal ? FilledButton.tonalIcon : FilledButton.icon;
    final label = Text(text, textAlign: TextAlign.center);
    final colors = Theme.of(context).colorScheme;
    // Tonal actions are accent-tinted capsules, primary ones solid accent.
    final style = _tonal
        ? styleOf(context).copyWith(
            backgroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.disabled)
                    ? colors.onSurface.withValues(alpha: 0.06)
                    : colors.primary.withValues(alpha: 0.12)),
            foregroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.disabled)
                    ? colors.onSurface.withValues(alpha: 0.38)
                    : colors.primary),
          )
        : styleOf(context);
    return button(
      onPressed: onPressed,
      style: style,
      icon: icon == null ? null : Icon(icon, size: 20),
      label: reserveText == null
          ? label
          : Stack(
              alignment: Alignment.center,
              children: [
                Visibility(
                  visible: false,
                  maintainSize: true,
                  maintainState: true,
                  maintainAnimation: true,
                  child: Text(reserveText!, textAlign: TextAlign.center),
                ),
                label,
              ],
            ),
    );
  }
}
