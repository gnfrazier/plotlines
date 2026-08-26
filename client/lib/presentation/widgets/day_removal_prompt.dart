// FR139 (Story Q1) / Author Flows MVP Flow 9 "Editing and cascades" — a day
// count reduction (or any direct day removal) that would orphan authored
// work states the scope and lets the Author decide, the same shape
// `trip_bbox_shrink_prompt.dart` already gives FR120's bbox shrink: keep
// (cancel) or remove explicitly, plus this case's own third option FR139
// names for it — merge the day's content into the adjacent day rather than
// losing it. Never shown for an empty day — that carve-out is the caller's
// job (`summarizeDayContent(day).isEmpty`), not this dialog's.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/edit_scope.dart';

enum DayRemovalChoice { keep, mergeIntoAdjacent, removeExplicitly }

/// Shows the scope prompt for removing [dayLabels] (e.g. "Day 5" or "Day 5
/// and Day 6"), which together hold [summary]. Returns the Author's choice,
/// or null if they dismissed the dialog without one (treated the same as
/// [DayRemovalChoice.keep] by the caller).
Future<DayRemovalChoice?> showDayRemovalPrompt(
  BuildContext context, {
  required String dayLabels,
  required DayContentSummary summary,
}) {
  return showDialog<DayRemovalChoice>(
    context: context,
    builder: (context) => _DayRemovalDialog(dayLabels: dayLabels, summary: summary),
  );
}

class _DayRemovalDialog extends StatelessWidget {
  const _DayRemovalDialog({required this.dayLabels, required this.summary});
  final String dayLabels;
  final DayContentSummary summary;

  String _describe() {
    final parts = <String>[
      if (summary.passages > 0) '${summary.passages} ${summary.passages == 1 ? 'passage' : 'passages'}',
      if (summary.anchors > 0) '${summary.anchors} ${summary.anchors == 1 ? 'anchor' : 'anchors'}',
      if (summary.scheduledEvents > 0)
        '${summary.scheduledEvents} scheduled ${summary.scheduledEvents == 1 ? 'event' : 'events'}',
    ];
    if (parts.length == 1) return parts.single;
    if (parts.length == 2) return '${parts[0]} and ${parts[1]}';
    return '${parts.sublist(0, parts.length - 1).join(', ')}, and ${parts.last}';
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return AlertDialog(
      title: Text('$dayLabels holds authored content', style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$dayLabels ${dayLabels.contains(' and ') ? 'hold' : 'holds'} ${_describe()}. '
              'Nothing is discarded silently — choose what happens to it.',
              style: PlotTypography.body(c.textSecondary),
            ),
          ],
        ),
      ),
      actions: [
        PlotButton(
          label: 'Keep',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(context, DayRemovalChoice.keep),
        ),
        PlotButton(
          label: 'Merge into adjacent day',
          variant: PlotButtonVariant.secondary,
          onPressed: () => Navigator.pop(context, DayRemovalChoice.mergeIntoAdjacent),
        ),
        PlotButton(
          label: 'Remove explicitly',
          variant: PlotButtonVariant.danger,
          onPressed: () => Navigator.pop(context, DayRemovalChoice.removeExplicitly),
        ),
      ],
    );
  }
}
