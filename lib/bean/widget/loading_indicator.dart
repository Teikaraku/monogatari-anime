import 'package:flutter/material.dart';

/// The thin accent spinner of the Monogatari apps, centred in a [size] box so
/// existing layouts keep their slot.
class LoadingIndicator extends StatelessWidget {
  const LoadingIndicator({
    super.key,
    this.size = 48,
    this.color,
    this.semanticsLabel = '加载中',
  });

  final double size;
  final Color? color;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final diameter = (size * 0.56).clamp(16.0, 36.0);
    return SizedBox.square(
      dimension: size,
      child: Center(
        child: SizedBox.square(
          dimension: diameter,
          child: CircularProgressIndicator(
            strokeWidth: diameter < 22 ? 2 : 2.5,
            strokeCap: StrokeCap.round,
            color: color ?? Theme.of(context).colorScheme.primary,
            semanticsLabel: semanticsLabel,
          ),
        ),
      ),
    );
  }
}
