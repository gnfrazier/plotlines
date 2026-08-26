// FR144/N0 — trip creation declares one or more travel modes, ahead of the
// location prompt (`trip_location_prompt.dart`) on the new-trip path
// (Author Flows MVP Flow 1's "Declare travel modes" node). At least one is
// required; every real mode stays offered regardless of what's picked
// (declaring is not a constraint — FR144). Mirrors `_TripLocationDialog`'s
// shape (a plain `AlertDialog`, Cancel/Continue) rather than inventing a new
// dialog pattern for what is, structurally, the same kind of step.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/travel_mode.dart';
import 'plot_toggle_chip.dart';
import 'travel_mode_icons.dart';

/// Returns the Author's declared set, or null if they cancelled trip
/// creation entirely (mirrors `showTripLocationPrompt`'s cancel contract).
/// [initialModes] preselects a later edit of an already-declared set — a
/// fresh trip creation calls this with none preselected.
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
  late final Set<String> _selected = {...widget.initialModes};

  void _toggle(String mode) {
    setState(() {
      _selected.contains(mode) ? _selected.remove(mode) : _selected.add(mode);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return AlertDialog(
      title: Text('How are we travelling?', style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This sets which map layers and passage modes the trip starts with — '
              'pick at least one. Nothing here is a limit: creating a passage in '
              'another mode later just adds it.',
              style: PlotTypography.body(c.textSecondary),
            ),
            const SizedBox(height: PlotSpacing.s4),
            Wrap(
              spacing: PlotSpacing.s2,
              runSpacing: PlotSpacing.s2,
              children: [
                for (final mode in kTravelModes)
                  PlotToggleChip(
                    label: travelModeLabel(mode),
                    icon: travelModeIcon(mode),
                    selected: _selected.contains(mode),
                    onTap: () => _toggle(mode),
                  ),
              ],
            ),
          ],
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
