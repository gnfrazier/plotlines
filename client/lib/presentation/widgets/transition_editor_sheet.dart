// FR12 / B3 — the editor for a transition node: the point between two
// passages where a Character switches activities, stashes gear, or executes a
// put-in / take-out, and the Author's instructions for doing it.
//
// A transition belongs to the day, not to either passage (`domain/
// transition.dart`), so this is deliberately *not* `node_editor_sheet.dart`
// with an extra field. That form edits a node on a passage — kind, POI type,
// amenities, arc stage, narration trigger — and none of those are questions
// about a junction. What a junction has is: which two modes meet, whether they
// meet at the same place (B2's gap), and what the Author needs the Character to
// do here. This form asks exactly those.
//
// Opened from the day timeline strip's transition glyph, which is where the
// junction is visible as a thing you can point at.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
import 'travel_mode_icons.dart';

/// Opens the transition editor for the junction [transition] in day [dayId].
Future<void> showTransitionEditorSheet(
  BuildContext context, {
  required String dayId,
  required Transition transition,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: TransitionEditorForm(
        dayId: dayId,
        transition: transition,
        onSaved: () => Navigator.pop(context),
      ),
    ),
  );
}

class TransitionEditorForm extends ConsumerStatefulWidget {
  const TransitionEditorForm({
    super.key,
    required this.dayId,
    required this.transition,
    required this.onSaved,
  });

  final String dayId;
  final Transition transition;
  final VoidCallback onSaved;

  @override
  ConsumerState<TransitionEditorForm> createState() => _TransitionEditorFormState();
}

class _TransitionEditorFormState extends ConsumerState<TransitionEditorForm> {
  late final _title =
      TextEditingController(text: widget.transition.node?.title ?? '');
  late final _instructions =
      TextEditingController(text: widget.transition.instructions ?? '');

  @override
  void dispose() {
    _title.dispose();
    _instructions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final t = widget.transition;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(PlotSpacing.s5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.isModeChange ? 'Mode change' : 'Transition',
            style: PlotTypography.h2(c.textPrimary).copyWith(fontSize: 20),
          ),
          const SizedBox(height: PlotSpacing.s2),
          _ModeChangeLine(transition: t),
          if (t.gapWarning ?? false) ...[
            const SizedBox(height: PlotSpacing.s3),
            Row(
              children: [
                const PlotBadge('GAP', tone: PlotBadgeTone.gold, solid: true),
                const SizedBox(width: PlotSpacing.s2),
                Expanded(
                  child: Text(
                    'These two passages do not meet — '
                    '${t.gapM == null ? 'an unmeasured distance' : '${t.gapM!.round()} m'} '
                    'between them. Say how a Character covers it.',
                    style: PlotTypography.small(c.textSecondary),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: PlotSpacing.s4),
          TextField(
            controller: _title,
            decoration: const InputDecoration(
              labelText: 'Title (e.g. "Put-in at Lyons")',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: PlotSpacing.s3),
          TextField(
            controller: _instructions,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Instructions',
              hintText: 'Where to park, stash gear, put in or take out.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: PlotSpacing.s2),
          Text(
            'Always visible to a Character — a put-in instruction held back '
            'until arrival is a Character standing on a bank holding a boat.',
            style: PlotTypography.small(c.textMuted),
          ),
          if (t.node?.coord != null) ...[
            const SizedBox(height: PlotSpacing.s3),
            Text(
              '${t.node!.coord[1].toStringAsFixed(5)}, ${t.node!.coord[0].toStringAsFixed(5)}',
              style: PlotTypography.data(c.textMuted),
            ),
          ],
          const SizedBox(height: PlotSpacing.s5),
          Row(
            children: [
              Expanded(
                child: PlotButton(
                  label: 'Save transition',
                  expand: true,
                  onPressed: _save,
                ),
              ),
              if (t.node != null) ...[
                const SizedBox(width: PlotSpacing.s3),
                PlotButton(
                  label: 'Remove',
                  variant: PlotButtonVariant.ghost,
                  onPressed: () {
                    ref
                        .read(currentTripProvider.notifier)
                        .removeTransitionNode(widget.dayId, t.id);
                    widget.onSaved();
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  void _save() {
    ref.read(currentTripProvider.notifier).setTransitionNode(
          widget.dayId,
          widget.transition.id,
          title: _title.text,
          instructions: _instructions.text,
        );
    widget.onSaved();
  }
}

/// "Ride → Paddle", with each mode's own glyph. A junction between two
/// passages of the same mode says so plainly instead of pretending to be a
/// mode change.
class _ModeChangeLine extends StatelessWidget {
  const _ModeChangeLine({required this.transition});
  final Transition transition;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final from = transition.fromMode;
    final to = transition.toMode;
    if (from == null || to == null) {
      return Text('Between two passages', style: PlotTypography.body(c.textSecondary));
    }
    if (!transition.isModeChange) {
      return Text(
        'Between two ${travelModeLabel(from).toLowerCase()} passages — same mode, '
        'so nothing to switch. Instructions still reach the timeline here.',
        style: PlotTypography.small(c.textSecondary),
      );
    }
    return Row(
      children: [
        Icon(travelModeIcon(from), size: 18, color: c.textSecondary),
        const SizedBox(width: PlotSpacing.s2),
        Text(travelModeLabel(from), style: PlotTypography.body(c.textPrimary)),
        const SizedBox(width: PlotSpacing.s2),
        Icon(Icons.arrow_forward, size: 16, color: c.textMuted),
        const SizedBox(width: PlotSpacing.s2),
        Icon(travelModeIcon(to), size: 18, color: c.textSecondary),
        const SizedBox(width: PlotSpacing.s2),
        Text(travelModeLabel(to), style: PlotTypography.body(c.textPrimary)),
      ],
    );
  }
}
