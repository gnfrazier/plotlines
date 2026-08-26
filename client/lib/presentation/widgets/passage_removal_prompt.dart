// FR139/FR140 (Story Q2) / Author Flows MVP Flow 9 "Editing and cascades" —
// removing a passage prompts if it carries authored content, naming any
// transition nodes with Author instructions specifically. Its anchors
// always survive unattached (`CurrentTripNotifier.removeSegment` moves them
// onto the day), so this dialog is purely the "may I remove this" gate FR139
// requires before authored content disappears — same shape as
// `trip_bbox_shrink_prompt.dart` (FR120) and `day_removal_prompt.dart`
// (FR139/Q1), one fewer choice: there's no "adjust the extent" of removing
// a single passage the way there is for a day-count reduction.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/edit_scope.dart';

/// Shows the removal prompt for a passage summarized by [summary]. Returns
/// true if the Author confirmed the removal, false/null otherwise (treated
/// as "keep" by the caller).
Future<bool?> showPassageRemovalPrompt(
  BuildContext context, {
  required SegmentContentSummary summary,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) => _PassageRemovalDialog(summary: summary),
  );
}

class _PassageRemovalDialog extends StatelessWidget {
  const _PassageRemovalDialog({required this.summary});
  final SegmentContentSummary summary;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return AlertDialog(
      title: Text('Remove this passage?', style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This passage carries ${summary.nodeCount} '
              '${summary.nodeCount == 1 ? 'node' : 'nodes'}'
              '${summary.hazardCount > 0 ? ' and ${summary.hazardCount} ${summary.hazardCount == 1 ? 'hazard' : 'hazards'}' : ''}. '
              'Its anchors survive unattached — findable and re-attachable from the '
              'anchors view — rather than being deleted with it.',
              style: PlotTypography.body(c.textSecondary),
            ),
            if (summary.instructedTransitionNodes.isNotEmpty) ...[
              const SizedBox(height: PlotSpacing.s3),
              Text('TRANSITION INSTRUCTIONS ON THIS PASSAGE',
                  style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: PlotSpacing.s2),
              for (final n in summary.instructedTransitionNodes)
                Padding(
                  padding: const EdgeInsets.only(bottom: PlotSpacing.s1),
                  child: Text('• ${n.instructions}', style: PlotTypography.data(c.textPrimary)),
                ),
            ],
          ],
        ),
      ),
      actions: [
        PlotButton(
          label: 'Keep',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(context, false),
        ),
        PlotButton(
          label: 'Remove passage',
          variant: PlotButtonVariant.danger,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
  }
}
