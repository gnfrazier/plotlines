// FR142(e) / K12a — the first surface to render `domain/teaching.dart`.
//
// The registry has existed since K12a with no consumer: the enumeration and
// its completeness test were built, but each moment's copy was still written
// inline wherever it was needed, which is how five blocks of standing prose
// ended up on the alternate branch card explaining the model instead of
// describing the alternate (issue #324). This is the block that copy belongs
// in — shown once per trip, dismissible, and reachable afterwards from the
// help affordance the registry entry names.
//
// Nothing here is load-bearing. A dismissed block hides copy and never
// disables a control, so K12a's "no teaching block is load-bearing" holds
// structurally rather than by review.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/teaching.dart';
import '../../state/providers.dart';

/// The dismissible first-run explanation for [moment] on this surface, or
/// nothing at all once it has been dismissed for [tripId].
class TeachingBlock extends ConsumerStatefulWidget {
  const TeachingBlock({super.key, required this.tripId, required this.moment});

  final String tripId;
  final TeachingMoment moment;

  @override
  ConsumerState<TeachingBlock> createState() => _TeachingBlockState();
}

class _TeachingBlockState extends ConsumerState<TeachingBlock> {
  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final copy = teachingRegistry[widget.moment];
    final dismissals = ref.read(teachingDismissalsProvider);
    if (copy == null || dismissals.isDismissed(widget.tripId, widget.moment)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: PlotSpacing.s2),
      child: PlotCard(
        sunk: true,
        padding: const EdgeInsets.all(PlotSpacing.s2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(copy.message, style: PlotTypography.small(c.textSecondary)),
            ),
            const SizedBox(width: PlotSpacing.s2),
            PlotButton(
              label: 'Got it',
              variant: PlotButtonVariant.ghost,
              onPressed: () => setState(
                () => dismissals.dismiss(widget.tripId, widget.moment),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// K12a's reachability half: the inline help affordance on the same surface
/// that keeps a dismissed tip readable. Named for the registry entry's
/// `helpAffordance`, so the two cannot drift apart silently.
class TeachingHelpIcon extends StatelessWidget {
  const TeachingHelpIcon({super.key, required this.moment});

  final TeachingMoment moment;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final copy = teachingRegistry[moment];
    if (copy == null) return const SizedBox.shrink();
    return Tooltip(
      // The key is the registry's own `helpAffordance` id: the surface and its
      // affordance are named in one place, and a test can find the affordance
      // by the name the registry claims for it.
      key: ValueKey(copy.helpAffordance),
      message: copy.message,
      child: Icon(Icons.help_outline, size: 14, color: c.textMuted),
    );
  }
}
