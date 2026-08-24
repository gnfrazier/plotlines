import 'package:flutter/material.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../theme/tokens.dart';

enum PlotBadgeTone { neutral, blaze, spruce, slate, gold, ember }

/// Small mono status label (e.g. OFFLINE READY, GRAVEL+PADDLE). Two styles:
/// [solid] fills with the tone color, otherwise a tinted chip with a border.
/// Gold is allowed here only as a fill behind ink text — never gold text.
class PlotBadge extends StatelessWidget {
  const PlotBadge(
    this.label, {
    super.key,
    this.tone = PlotBadgeTone.neutral,
    this.solid = false,
  });

  final String label;
  final PlotBadgeTone tone;
  final bool solid;

  Color _color(PlotColors c) {
    switch (tone) {
      case PlotBadgeTone.neutral:
        return c.textSecondary;
      case PlotBadgeTone.blaze:
        return c.primary;
      case PlotBadgeTone.spruce:
        return c.success;
      case PlotBadgeTone.slate:
        return c.info;
      case PlotBadgeTone.gold:
        return c.warning;
      case PlotBadgeTone.ember:
        return c.danger;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final tint = _color(c);
    // On a gold or otherwise light fill, use ink text; else paper.
    final onSolid =
        tone == PlotBadgeTone.gold ? PlotColors.ink : Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: solid ? tint : tint.withValues(alpha: 0.12),
        borderRadius: const BorderRadius.all(PlotRadii.sm),
        border: solid ? null : Border.all(color: tint.withValues(alpha: 0.5)),
      ),
      child: Text(
        label.toUpperCase(),
        style: PlotTypography.data(solid ? onSolid : tint).copyWith(
          fontSize: 10,
          letterSpacing: 0.06 * 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
