// N1 (PRD FR120) / Author Flows MVP Flow 9 "Shrinking the bounding box" —
// "you are shown which anchors fall outside... nothing is discarded
// silently." Three choices, matching `client/design/Flow 9 - Editing and
// cascades.dc.html` §03: keep the bounds where they are (cancel), move the
// bounds to include every affected anchor (no re-extraction — FR120 says
// enlarging only fetches the added strip), or remove those anchors
// explicitly (an authored, visible act, never a side effect of resizing).
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/trip_bbox.dart';
import '../../domain/trip_bbox_revision.dart';

enum BboxShrinkChoice { keepBounds, moveBounds, removeAnchors }

/// Shows the shrink prompt for the anchors in [outside]. Returns the
/// Author's choice, or null if they dismissed the dialog without one
/// (treated the same as [BboxShrinkChoice.keepBounds] by the caller).
Future<BboxShrinkChoice?> showBboxShrinkPrompt(
  BuildContext context, {
  required List<AnchorLocation> outside,
}) {
  return showDialog<BboxShrinkChoice>(
    context: context,
    builder: (context) => _BboxShrinkDialog(outside: outside),
  );
}

class _BboxShrinkDialog extends StatelessWidget {
  const _BboxShrinkDialog({required this.outside});
  final List<AnchorLocation> outside;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final count = outside.length;
    final noun = count == 1 ? 'anchor' : 'anchors';
    return AlertDialog(
      title: Text('$count $noun would fall outside', style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Nothing is discarded silently. Choose what happens to ${count == 1 ? 'it' : 'them'}, '
              'or move the bounds instead.',
              style: PlotTypography.body(c.textSecondary),
            ),
            const SizedBox(height: PlotSpacing.s3),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final a in outside)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: PlotSpacing.s1),
                        child: Text(a.label, style: PlotTypography.data(c.textPrimary)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: PlotSpacing.s2),
            Text(
              'The bbox is revisable. What is fixed is that there is never a second, '
              'different extent for analysis.',
              style: PlotTypography.small(c.textMuted),
            ),
          ],
        ),
      ),
      actions: [
        PlotButton(
          label: 'Keep the bounds where they are',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(context, BboxShrinkChoice.keepBounds),
        ),
        PlotButton(
          label: 'Move the bounds to include ${count == 1 ? 'it' : 'all $count'}',
          variant: PlotButtonVariant.secondary,
          onPressed: () => Navigator.pop(context, BboxShrinkChoice.moveBounds),
        ),
        PlotButton(
          label: 'Remove ${count == 1 ? 'this anchor' : 'these $count anchors'}',
          variant: PlotButtonVariant.danger,
          onPressed: () => Navigator.pop(context, BboxShrinkChoice.removeAnchors),
        ),
      ],
    );
  }
}

/// Proposes revising the trip bbox to [proposed]. If none of [anchors] would
/// fall outside it, applies immediately — this is what makes a pure
/// enlargement a no-prompt path without a separate "is this a shrink"
/// check (`anchorsOutsideBbox`'s doc comment). Otherwise shows the shrink
/// prompt and applies whatever the Author decides:
/// - keep bounds (or dismiss): does nothing, [proposed] is discarded.
/// - move bounds: applies the smallest box containing [proposed] plus every
///   excluded anchor.
/// - remove anchors: calls [onRemoveAnchors] with exactly the anchors that
///   fell outside, then applies [proposed] as drawn.
Future<void> reviseTripBbox(
  BuildContext context, {
  required TripBbox proposed,
  required List<AnchorLocation> anchors,
  required ValueChanged<TripBbox> onApply,
  ValueChanged<List<AnchorLocation>>? onRemoveAnchors,
}) async {
  final outside = anchorsOutsideBbox(proposed, anchors);
  if (outside.isEmpty) {
    onApply(proposed);
    return;
  }
  final choice = await showBboxShrinkPrompt(context, outside: outside);
  switch (choice) {
    case BboxShrinkChoice.moveBounds:
      onApply(proposed.expandToInclude([for (final a in outside) a.point]));
    case BboxShrinkChoice.removeAnchors:
      onRemoveAnchors?.call(outside);
      onApply(proposed);
    case BboxShrinkChoice.keepBounds:
    case null:
      break;
  }
}
