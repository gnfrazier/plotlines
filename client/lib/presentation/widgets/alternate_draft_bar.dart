// #324 — the panel that runs the alternate-drawing gesture on the Route tab.
//
// It says one thing at a time: what to tap next, and — once the fork and the
// rejoin are both on the line — what has been drawn. The alternate is created
// from here, and the card opens afterwards on a path that exists.
//
// The instruction comes from `AlternateDraft.blocker` rather than from a
// disabled button with no explanation: a Create button the Author cannot press
// has to say why, and the draft already knows.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';

class AlternateDraftBar extends StatelessWidget {
  const AlternateDraftBar({
    super.key,
    required this.draft,
    required this.displayFormat,
    required this.onUndo,
    required this.onCancel,
    required this.onCreate,
  });

  final AlternateDraft draft;
  final DisplayFormat displayFormat;

  /// Take back the last placement (a shape point, else the rejoin, else the
  /// fork). Null once there is nothing placed to take back.
  final VoidCallback? onUndo;
  final VoidCallback onCancel;

  /// Null while [AlternateDraft.blocker] is non-null.
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final blocker = draft.blocker;
    return PlotCard(
      padding: const EdgeInsets.all(PlotSpacing.s3),
      child: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('DRAWING AN ALTERNATE', style: PlotTypography.data(c.textMuted)),
            const SizedBox(height: PlotSpacing.s2),
            Text(
              blocker ?? 'Tap to shape the path, or create it as it is.',
              style: PlotTypography.body(c.textSecondary),
            ),
            if (draft.divergesAtM != null) ...[
              const SizedBox(height: PlotSpacing.s3),
              Wrap(
                spacing: PlotSpacing.s2,
                runSpacing: PlotSpacing.s1,
                children: [
                  PlotBadge('LEAVES ${displayFormat.formatDistance(draft.divergesAtM!)}'),
                  if (draft.rejoinsAtM != null)
                    PlotBadge('REJOINS ${displayFormat.formatDistance(draft.rejoinsAtM!)}'),
                  if (draft.deltaM != null)
                    PlotBadge(
                      '${draft.deltaM! < 0 ? '−' : '+'}'
                      '${displayFormat.formatDistance(draft.deltaM!.abs())}',
                      tone: PlotBadgeTone.gold,
                    ),
                ],
              ),
            ],
            const SizedBox(height: PlotSpacing.s3),
            // Wrapped rather than a fixed row: the panel sits over the map at
            // whatever width the workspace leaves it, and three buttons at
            // brand label sizes do not always fit on one line.
            Wrap(
              alignment: WrapAlignment.end,
              spacing: PlotSpacing.s2,
              runSpacing: PlotSpacing.s2,
              children: [
                PlotButton(
                  label: 'Undo point',
                  variant: PlotButtonVariant.ghost,
                  onPressed: onUndo,
                ),
                PlotButton(
                  label: 'Cancel',
                  variant: PlotButtonVariant.ghost,
                  onPressed: onCancel,
                ),
                PlotButton(label: 'Create alternate', onPressed: onCreate),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
