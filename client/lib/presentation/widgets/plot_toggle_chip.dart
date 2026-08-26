// The app's established toggle-chip look (see `_SegmentChip` in
// `day_timeline_strip.dart`) — a bordered box, filled + accent border when
// selected — used in place of Material's default `ChoiceChip`/`FilterChip`
// so mode/shape/theme pickers match the rest of the app instead of the
// stock Material chip style. Promoted out of `new_route_screen.dart` (FR144/
// N0) so `trip_mode_prompt.dart`'s mode-declaration dialog uses the same
// look rather than reaching for a stock chip.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

class PlotToggleChip extends StatelessWidget {
  const PlotToggleChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: PlotRadii.controlShape,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
        decoration: BoxDecoration(
          color: selected ? c.primary.withValues(alpha: 0.1) : c.surfaceCard,
          border: Border.all(color: selected ? c.primary : c.border, width: selected ? 1.5 : 1),
          borderRadius: PlotRadii.controlShape,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: selected ? c.primary : c.textSecondary),
              const SizedBox(width: PlotSpacing.s2),
            ],
            Text(
              label,
              style: PlotTypography.data(selected ? c.primary : c.textPrimary)
                  .copyWith(fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}
