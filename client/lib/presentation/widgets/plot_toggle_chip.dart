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
    // Issue #230 B5 — selected/unselected differed by hue alone (orange
    // border, text and icon against neutral), which is WCAG 1.4.1. A
    // selected chip now also carries a filled ground and a leading check,
    // so the state survives being read without colour.
    return Semantics(
      selected: selected,
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: PlotRadii.controlShape,
        child: Container(
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(
              horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
          decoration: BoxDecoration(
            color: selected ? c.primary.withValues(alpha: 0.14) : c.surfaceCard,
            border: Border.all(color: selected ? c.primary : c.border, width: selected ? 1.5 : 1),
            borderRadius: PlotRadii.controlShape,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                Icon(Icons.check, size: 15, color: c.primary),
                const SizedBox(width: PlotSpacing.s1),
              ],
              if (icon != null) ...[
                Icon(icon, size: 16, color: selected ? c.primary : c.textSecondary),
                const SizedBox(width: PlotSpacing.s2),
              ],
              // Issue #230 A1 — a chip label is an interactive control
              // label, not data: sans, not mono with 0.12em tracking.
              Text(
                label,
                style: PlotTypography.label(selected ? c.primary : c.textPrimary)
                    .copyWith(fontWeight: selected ? FontWeight.w700 : FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
