// FR144/N0 — trip creation declares one or more travel **categories**, ahead
// of the location prompt (`trip_location_prompt.dart`) on the new-trip path
// (Author Flows MVP Flow 1's "Declare travel modes" node). At least one is
// required; every category stays offered regardless of what's picked
// (declaring is not a constraint — FR144). Mirrors `_TripLocationDialog`'s
// shape (a plain `AlertDialog`, Cancel/Continue) rather than inventing a new
// dialog pattern for what is, structurally, the same kind of step.
//
// Issue #315 — this is category selection now: Cycle · Foot · Paddle · Ski ·
// Drive as five equal targets, no "common vs every other mode" tiering and no
// disclosure. A specific *discipline* (road vs gravel vs mountain, and so on)
// is picked per passage, not here. `transit` is a note mode (FR29) and never
// appears in a "how will you travel" list.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/legacy_mode.dart';
import '../../domain/travel_mode.dart';
import 'plot_toggle_chip.dart';
import 'travel_mode_icons.dart';

/// Returns the Author's declared set of travel-mode categories, or null if
/// they cancelled trip creation entirely (mirrors `showTripLocationPrompt`'s
/// cancel contract). [initialModes] preselects a later edit of an
/// already-declared set — a fresh trip creation calls this with none
/// preselected. Legacy values are folded onto their category; a value that is
/// not a category (a stray `transit`) is dropped from the preselection.
Future<Set<String>?> showTripModePrompt(
  BuildContext context, {
  Set<String> initialModes = const {},
}) {
  return showDialog<Set<String>>(
    context: context,
    builder: (context) => _TripModeDialog(initialModes: initialModes),
  );
}

class _TripModeDialog extends StatefulWidget {
  const _TripModeDialog({required this.initialModes});
  final Set<String> initialModes;

  @override
  State<_TripModeDialog> createState() => _TripModeDialogState();
}

class _TripModeDialogState extends State<_TripModeDialog> {
  late final Set<String> _selected = {
    for (final m in widget.initialModes)
      if (kTravelCategories.contains(canonicalMode(m))) canonicalMode(m),
  };

  void _toggle(String category) {
    setState(() {
      _selected.contains(category)
          ? _selected.remove(category)
          : _selected.add(category);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return AlertDialog(
      title: Text('How will you travel?', style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                // Issue #316 — layer selection is its own step now (after the
                // extent). Issue #315 — a discipline is a per-passage choice,
                // so this only asks for the broad category.
                'Pick the broad ways this trip travels — at least one. This seeds the '
                'map layers you\'ll confirm on the layer step, and the modes offered when '
                'you add a passage. You\'ll choose a specific discipline — road, gravel or '
                'mountain, say — on each passage. Nothing here is a limit: adding a '
                'passage in another mode later just adds it.',
                style: PlotTypography.body(c.textSecondary),
              ),
              const SizedBox(height: PlotSpacing.s4),
              Wrap(
                spacing: PlotSpacing.s2,
                runSpacing: PlotSpacing.s2,
                children: [
                  for (final category in kTravelCategories)
                    PlotToggleChip(
                      label: travelCategoryLabel(category),
                      icon: travelModeIcon(category),
                      selected: _selected.contains(category),
                      onTap: () => _toggle(category),
                    ),
                ],
              ),
              // FR144 AC: "at least one is required" — stated where the
              // constraint bites, next to a Continue that is genuinely
              // disabled until it is met (issue #230 B5).
              if (_selected.isEmpty) ...[
                const SizedBox(height: PlotSpacing.s3),
                Row(
                  children: [
                    Icon(Icons.info_outline, size: 15, color: c.textMuted),
                    const SizedBox(width: PlotSpacing.s2),
                    Expanded(
                      child: Text('Pick at least one to continue.',
                          style: PlotTypography.small(c.textSecondary)),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        PlotButton(
          label: 'Cancel',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(context),
        ),
        PlotButton(
          label: 'Continue',
          // FR144 AC: "at least one is required."
          onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, _selected),
        ),
      ],
    );
  }
}
