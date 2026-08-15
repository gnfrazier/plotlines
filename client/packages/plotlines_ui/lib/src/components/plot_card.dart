import 'package:flutter/material.dart';
import '../theme/colors.dart';
import '../theme/tokens.dart';

/// A paper surface with a hairline border and soft optional shadow — the base
/// container for the whole system. Borders do the structural work.
class PlotCard extends StatelessWidget {
  const PlotCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(PlotSpacing.s5),
    this.onTap,
    this.raised = false,
    this.sunk = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool raised;
  final bool sunk;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: padding,
      decoration: BoxDecoration(
        color: sunk ? c.surfaceSunk : c.surfaceCard,
        borderRadius: const BorderRadius.all(PlotRadii.lg),
        border: Border.all(color: c.border),
        boxShadow: raised ? PlotElevation.soft(PlotColors.ink) : null,
      ),
      child: child,
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(PlotRadii.lg),
        child: content,
      ),
    );
  }
}
