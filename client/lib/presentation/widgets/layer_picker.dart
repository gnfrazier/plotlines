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
    this.layerStates = const {},
  });

  /// The full catalog (FR97's AC — spans the OSM taxonomy).
  final List<String> layers;

  /// The subset currently live.
  final Set<String> live;
  final void Function(String layer) onToggle;

  /// `/health`'s `capabilities.layers.per_layer` — `'ready'` / `'loading'` /
  /// `'failed:<reason>'` per layer id (ARCH §8.3, story N2). A layer not
  /// present here is treated as ready (every built-in OSM layer). A `loading`
  /// layer shows a spinner and cannot be toggled yet; a `failed` layer shows
  /// why and is disabled — one slow or broken plugin dataset never blocks
  /// the rest of the picker or the workspace.
  final Map<String, String> layerStates;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: PlotSpacing.s2,
      runSpacing: PlotSpacing.s2,
      children: [
        for (final layer in layers) _chipFor(context, layer),
      ],
    );
  }

  Widget _chipFor(BuildContext context, String layer) {
    final label = layerLabels[layer] ?? layer;
    final state = layerStates[layer] ?? 'ready';
    if (state == 'ready') {
      return FilterChip(
        label: Text(label),
        selected: live.contains(layer),
        onSelected: (_) => onToggle(layer),
      );
    }
    if (state == 'loading') {
      return FilterChip(
        avatar: const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: Text('$label — loading'),
        selected: false,
        onSelected: null, // disabled until the dataset settles
      );
    }
    // failed:<reason>
    final reason = state.contains(':') ? state.split(':').sublist(1).join(':') : state;
    return Tooltip(
      message: '$label unavailable — $reason',
      child: FilterChip(
        avatar: Icon(Icons.error_outline, size: 16, color: Theme.of(context).colorScheme.error),
        label: Text('$label — unavailable'),
        selected: false,
        onSelected: null,
      ),
    );
  }
}
