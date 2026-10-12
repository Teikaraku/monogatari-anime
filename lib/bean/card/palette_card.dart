import 'package:flutter/material.dart';

/// A round accent swatch; the chosen one carries a check and a ring.
class PaletteCard extends StatelessWidget {
  final Color color;
  final bool selected;

  const PaletteCard({
    super.key,
    required this.color,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final onColor =
        color.computeLuminance() > 0.55 ? Colors.black : Colors.white;
    return Padding(
      padding: const EdgeInsets.all(6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 52,
        height: 52,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? color : Colors.transparent,
            width: 2,
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: selected
              ? Icon(Icons.check_rounded, color: onColor, size: 22)
              : null,
        ),
      ),
    );
  }
}
