// Issue #319 — the per-passage mode control, shared by New Route's first
// passage and the Route tab's rail (`weights_rail.dart`) so the two never
// drift apart again.
//
// The walkthrough (#271) found the trip's mode set and the per-passage pick
// drawn identically, ~500 px apart, with the second offering eight modes to
// the first's three. #319 settled the model: the trip has **one** stored
// mode set (`Trip.modes`), and a passage picks **one of those**. So the two
// controls have to read as different kinds of thing — the trip set is
// multi-select ownership (checked chips, `PlotToggleChip`, the same control
// `trip_mode_prompt.dart` uses one level up), and this is a single-select
// pick-from-parent: a segmented control, exactly one segment lit, and never
// a segment the trip does not have. "I need Drive for this one passage" is
// therefore: add Drive to the trip, then pick it here — the add affordance
// sits on this control so that is one gesture, not a hunt.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/travel_mode.dart';
import '../../state/current_trip_provider.dart';
import 'travel_mode_icons.dart';
import 'trip_mode_prompt.dart';

/// The modes a passage may be, in the canonical list order: the trip's set,
/// restricted to [offerable] (traversal modes for a generated route; every
/// wire mode for an existing passage, so a `transit` note leg keeps its
/// own). [current] — an existing passage's mode — is always offered even
/// if the set somehow lacks it, so the control can never show a passage
/// with nothing selected; `_replaceDay` folds such a mode into the set on
/// the next mutation anyway.
List<String> passageModesOffered(
  Set<String> tripModes, {
  List<String> offerable = kTraversalModes,
  String? current,
}) =>
    [
      for (final m in offerable)
        if (tripModes.contains(m) || m == current) m,
    ];

class PassageModePicker extends ConsumerWidget {
  const PassageModePicker({
    super.key,
    required this.selected,
    required this.onSelected,
    this.offerable = kTraversalModes,
    this.dense = false,
  });

  /// The passage's current mode, or null while a first passage has none
  /// yet — #319: nothing is preselected, the Author picks.
  final String? selected;
  final ValueChanged<String> onSelected;

  /// Which wire modes may appear at all — see [passageModesOffered].
  final List<String> offerable;

  /// The rail's tighter setting: uppercase data labels.
  final bool dense;

  Future<void> _addMode(BuildContext context, WidgetRef ref) async {
    final trip = ref.read(currentTripProvider);
    final modes = await showTripModePrompt(context, initialModes: trip.modes);
    if (modes == null) return;
    ref.read(currentTripProvider.notifier).setModes(modes);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final tripModes = ref.watch(currentTripProvider.select((t) => t.modes));
    final offered = passageModesOffered(tripModes, offerable: offerable, current: selected);
    final labelStyle = dense
        ? PlotTypography.data(c.textPrimary)
        : PlotTypography.label(c.textPrimary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (offered.isEmpty)
          Text(
            'This trip has no mode a passage can be yet — add one to the trip first.',
            style: PlotTypography.small(c.textSecondary),
          )
        else
          // Never wraps: a segmented control is one row by definition. The
          // rail is 305 px, so five modes scroll rather than overflow.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
              segments: [
                for (final m in offered)
                  ButtonSegment(
                    value: m,
                    icon: Icon(travelModeIcon(m), size: 16),
                    label: Text(
                      dense ? travelModeLabel(m).toUpperCase() : travelModeLabel(m),
                      style: labelStyle,
                    ),
                  ),
              ],
              selected: {if (selected != null && offered.contains(selected)) selected!},
              emptySelectionAllowed: true,
              showSelectedIcon: false,
              onSelectionChanged: (s) {
                // A tap on the lit segment reports an empty set; a passage
                // always has a mode, so that is a no-op, not a clear.
                if (s.isEmpty) return;
                onSelected(s.first);
              },
            ),
          ),
        // Right-aligned and scale-to-fit rather than in a Row beside a
        // helper line: the rail is 308 px, and the surface's own section
        // copy already says what this control is (no permanent caption
        // restating the rule — FR142(e)).
        Align(
          alignment: Alignment.centerRight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: PlotButton(
              label: 'Add a mode to the trip',
              variant: PlotButtonVariant.ghost,
              icon: Icons.add,
              onPressed: () => _addMode(context, ref),
            ),
          ),
        ),
      ],
    );
  }
}
