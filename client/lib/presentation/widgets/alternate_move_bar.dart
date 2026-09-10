// #344 — the panel that runs `Move on the map` on the Route tab: the gesture
// for an alternate that already exists.
//
// It is deliberately the sibling of `alternate_draft_bar.dart` rather than a
// second idiom. Drawing one and moving one are the same vocabulary — tap the
// route to place a mark, tap the map to shape the path — so the panel that
// runs them looks and reads the same, and the instruction still comes from the
// value's own `blocker` rather than from a disabled button with no explanation.
//
// The one thing this panel has that the draft bar does not is a *handle
// picker*. A draft is placed in order and the next tap is never ambiguous; an
// existing alternate has every handle already placed, so the Author has to say
// which one they mean before a tap can move it. Nothing is grabbed by default —
// panning a map must not silently drag whatever was last selected.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';
import 'plot_toggle_chip.dart';

class AlternateMoveBar extends StatelessWidget {
  const AlternateMoveBar({
    super.key,
    required this.edit,
    required this.label,
    required this.displayFormat,
    required this.onGrab,
    required this.onAddPoint,
    required this.onRemovePoint,
    required this.onCancel,
    required this.onDone,
  });

  final AlternateEdit edit;

  /// The alternate's own name, so the panel says which path is being moved —
  /// a passage can carry several and they all draw the same way.
  final String label;
  final DisplayFormat displayFormat;

  /// Grab a handle: [AlternateHandle.fork], [AlternateHandle.rejoin], or the
  /// [index]th shaping point.
  final void Function(AlternateHandle handle, int index) onGrab;

  /// Arm the next tap to insert a new shaping point where it lands.
  final VoidCallback onAddPoint;

  /// Take the grabbed shaping point out of the path. Null unless one is
  /// grabbed — the fork and the rejoin are what make this a divergence, so
  /// removing one is deleting the alternate, which is a confirming action on
  /// the card and not an option here.
  final VoidCallback? onRemovePoint;

  final VoidCallback onCancel;

  /// Save the moved path. Null while [AlternateEdit.blocker] is non-null.
  final VoidCallback? onDone;

  /// What the next tap does, said as an instruction rather than left to be
  /// inferred from a highlighted chip.
  String _instruction() {
    final blocker = edit.blocker;
    switch (edit.handle) {
      case AlternateHandle.fork:
        return 'Tap the route where this path should leave it.';
      case AlternateHandle.rejoin:
        return 'Tap the route where this path should come back.';
      case AlternateHandle.shapePoint:
        return 'Tap where this point should go.';
      case AlternateHandle.newShapePoint:
        return 'Tap to add a point to the path.';
      case null:
        return blocker ?? 'Pick a mark to move, or add a point to the path.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final shapeCount = edit.shape.length;
    return PlotCard(
      padding: const EdgeInsets.all(PlotSpacing.s3),
      child: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('MOVING $label'.toUpperCase(), style: PlotTypography.data(c.textMuted)),
            const SizedBox(height: PlotSpacing.s2),
            Text(_instruction(), style: PlotTypography.body(c.textSecondary)),
            const SizedBox(height: PlotSpacing.s3),
            // The handles in path order, so the row reads as the line does:
            // leaves, the points along it, rejoins.
            Wrap(
              spacing: PlotSpacing.s2,
              runSpacing: PlotSpacing.s2,
              children: [
                PlotToggleChip(
                  label: 'Leaves',
                  selected: edit.handle == AlternateHandle.fork,
                  onTap: () => onGrab(AlternateHandle.fork, 0),
                ),
                for (var i = 0; i < shapeCount; i++)
                  PlotToggleChip(
                    label: 'Point ${i + 1}',
                    selected: edit.handle == AlternateHandle.shapePoint &&
                        edit.handleIndex == i,
                    onTap: () => onGrab(AlternateHandle.shapePoint, i),
                  ),
                PlotToggleChip(
                  label: 'Rejoins',
                  selected: edit.handle == AlternateHandle.rejoin,
                  onTap: () => onGrab(AlternateHandle.rejoin, 0),
                ),
              ],
            ),
            if (edit.divergesAtM != null) ...[
              const SizedBox(height: PlotSpacing.s3),
              Wrap(
                spacing: PlotSpacing.s2,
                runSpacing: PlotSpacing.s1,
                children: [
                  PlotBadge('LEAVES ${displayFormat.formatDistance(edit.divergesAtM!)}'),
                  if (edit.rejoinsAtM != null)
                    PlotBadge('REJOINS ${displayFormat.formatDistance(edit.rejoinsAtM!)}'),
                  if (edit.deltaM != null)
                    PlotBadge(
                      '${edit.deltaM! < 0 ? '−' : '+'}'
                      '${displayFormat.formatDistance(edit.deltaM!.abs())}',
                      tone: PlotBadgeTone.gold,
                    ),
                ],
              ),
            ],
            if (edit.staleAfterMove) ...[
              const SizedBox(height: PlotSpacing.s2),
              // FR140/D-O said before the Author commits: nothing is being
              // destroyed and nothing will be asked, so this is a statement of
              // what happens next, not a warning and not a confirmation.
              Row(
                children: [
                  Icon(Icons.sync_problem, size: 14, color: c.warning),
                  const SizedBox(width: PlotSpacing.s1),
                  Expanded(
                    child: Text(
                      'This path was solved. Moving it leaves its distances stale '
                      'until you re-solve it — nothing is lost and nothing re-solves '
                      'on its own.',
                      style: PlotTypography.small(c.textMuted),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: PlotSpacing.s3),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: PlotSpacing.s2,
              runSpacing: PlotSpacing.s2,
              children: [
                PlotButton(
                  label: 'Add a point',
                  variant: edit.handle == AlternateHandle.newShapePoint
                      ? PlotButtonVariant.secondary
                      : PlotButtonVariant.ghost,
                  onPressed: onAddPoint,
                ),
                PlotButton(
                  label: 'Remove point',
                  variant: PlotButtonVariant.ghost,
                  onPressed: onRemovePoint,
                ),
                PlotButton(
                  label: 'Cancel',
                  variant: PlotButtonVariant.ghost,
                  onPressed: onCancel,
                ),
                PlotButton(label: 'Done', onPressed: onDone),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
