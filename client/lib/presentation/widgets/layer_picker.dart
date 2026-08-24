// FR97 — toggle which data layers are live. Used both for a trip's default
// selection and, given a `dayId`, for a single day's override.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

/// Author-facing labels for `taxonomy.LAYERS`. Kept here rather than in
/// `domain/` since it's presentation-only naming, not a payload shape.
const Map<String, String> layerLabels = {
  'sight': 'Sightseeing',
  'amenity': 'Amenities',
  'natural': 'Natural',
  'historic': 'Historic',
  'leisure': 'Leisure',
  'man_made': 'Man-made',
};

class LayerPicker extends StatelessWidget {
  const LayerPicker({
    super.key,
    required this.layers,
    required this.live,
    required this.onToggle,
  });

  /// The full catalog (FR97's AC — spans the OSM taxonomy).
  final List<String> layers;

  /// The subset currently live.
  final Set<String> live;
  final void Function(String layer) onToggle;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: PlotSpacing.s2,
      runSpacing: PlotSpacing.s2,
      children: [
        for (final layer in layers)
          FilterChip(
            label: Text(layerLabels[layer] ?? layer),
            selected: live.contains(layer),
            onSelected: (_) => onToggle(layer),
          ),
      ],
    );
  }
}
