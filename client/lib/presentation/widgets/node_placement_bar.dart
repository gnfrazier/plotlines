// #588 — the panel that runs node placement on the Route tab.
//
// Placement used to be armed by the same button that then relabelled itself
// "Tap map to place node…": an instruction where the way out should be, so an
// Author who changed their mind had nothing to press. This is the Flow 11
// gesture panel (`AlternateDraftBar`, `AlternateMoveBar`) applied to the one
// map gesture that did not have one, so the Route tab has a single way of
// saying "a map gesture is in progress" — and a single way out of it.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

class NodePlacementBar extends StatelessWidget {
  const NodePlacementBar({super.key, required this.onCancel});

  /// Disarm placement. Nothing has reached the trip, so this costs nothing.
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return PlotCard(
      padding: const EdgeInsets.all(PlotSpacing.s3),
      child: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('PLACING A NODE', style: PlotTypography.data(c.textMuted)),
            const SizedBox(height: PlotSpacing.s2),
            Text(
              'Click the map to place a node. Esc or Cancel stops without placing one.',
              style: PlotTypography.body(c.textSecondary),
            ),
            const SizedBox(height: PlotSpacing.s3),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: PlotSpacing.s2,
              runSpacing: PlotSpacing.s2,
              children: [
                PlotButton(
                  label: 'Cancel',
                  variant: PlotButtonVariant.ghost,
                  onPressed: onCancel,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
