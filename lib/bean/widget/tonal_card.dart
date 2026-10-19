import 'package:flutter/material.dart';

import 'package:kazumi/bean/widget/split_list_row.dart';

const double tonalCardRadius = 12;

class TonalCard extends StatelessWidget {
  const TonalCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Material(
        color: monoCellColor(context),
        borderRadius: BorderRadius.circular(tonalCardRadius),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: padding, child: child),
      );
}
