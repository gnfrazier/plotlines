// Issue #316 — the trip-creation layer step. It sits between the extent step
// (`trip_area_screen.dart`) and the first route (`new_route_screen.dart`),
// so the Author chooses what the map surfaces *before* a route is drawn
// rather than three screens later on the Layers tab. This is the pipeline's
// own order (PRD §5 / ARCH §4): layer selection is stage 2, routing is
// stage 7.
//
// What moved here is only the *initial* selection. The Layers tab
// (`plan_tabs/layers_tab.dart`) stays the curation workspace — candidates,
// proposals, anchors — and remains a working surface for the whole trip;
// this step just gives it a starting set and warms candidate extraction
// while the Author fills in the New Route form.
//
// Skippable with the default (PRD §5: "every stage after Display is
// skippable"): Continue is always live, and pressing it without touching a
// chip proceeds on the mode-derived default set.
//
// No map here, deliberately. The extent was just confirmed one screen back;
// this step is a set of layer toggles and a Continue. A `TripAreaMap` with
// its corner handles would be a second, unnamed way to revise the bbox
// mid-step (its named path is `trip_shell_screen.dart`'s app-bar action).
library;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/travel_mode.dart';
import '../../state/current_trip_provider.dart';
import '../../state/layer_selection_provider.dart';
import '../../state/providers.dart';
import '../../state/trip_bbox_provider.dart';
import '../../state/trip_candidates_provider.dart';
import '../widgets/layer_picker.dart';

class TripLayersScreen extends ConsumerStatefulWidget {
  const TripLayersScreen({super.key, this.initialCenter});

  /// Forwarded straight through to New Route (A10 — centers that screen's
  /// map only). This step neither reads nor changes it.
  final List<double>? initialCenter;

  @override
  ConsumerState<TripLayersScreen> createState() => _TripLayersScreenState();
}

class _TripLayersScreenState extends ConsumerState<TripLayersScreen> {
  /// FR144/N0 — the declared modes feed the picker's defaults. Same fallback
  /// chain `layers_tab.dart`'s `_effectiveModes` draws: a trip saved before
  /// N0 has nothing declared, so fall back to the modes realised in its
  /// segments, then to cycling for a brand-new, day-less trip.
  Set<String> get _effectiveModes {
    final trip = ref.read(currentTripProvider);
    if (trip.declaredModes.isNotEmpty) return trip.declaredModes;
    if (trip.modes.isNotEmpty) return trip.modes;
    return const {'cycling'};
  }

  void _continue() {
    // Kick candidate extraction off now, on the settled live set, so it is
    // warming while the Author works through New Route rather than starting
    // cold on first entry to the Layers tab. Fire-and-forget: the tab reads
    // `tripCandidatesProvider`'s loading/result state when it opens.
    final bbox = ref.read(tripBboxProvider);
    if (bbox != null) {
      final live = ref.read(layerSelectionProvider).tripLive;
      ref.read(tripCandidatesProvider.notifier).fetch(bbox: bbox, liveLayers: live);
    }
    context.push('/new', extra: widget.initialCenter);
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final modes = _effectiveModes;
    final catalogAsync = ref.watch(
      layerCatalogProvider((modes: layerModesKey(modes), dayType: 'route')),
    );
    final selection = ref.watch(layerSelectionProvider);
    final layerStates =
        ref.watch(sidecarManagerProvider).capabilities?.layersPerLayer ?? const {};

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to the trip extent',
          onPressed: () => context.pop(),
        ),
        title: const Text('New trip · layers'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: PlotSpacing.s4),
            child: Center(
              child: Text('NEW TRIP · STEP 3 OF 4',
                  style: PlotTypography.eyebrow(c.textMuted)),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: catalogAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Padding(
              padding: const EdgeInsets.all(PlotSpacing.s6),
              child: Text('Could not load the layer catalog: $err',
                  style: PlotTypography.body(c.danger), textAlign: TextAlign.center),
            ),
            data: (catalog) {
              // FR144/N0 — reseed the trip-wide live set from the
              // mode-derived default, but only when the declared set has
              // actually changed since the last seed (`seedForModes`'s own
              // contract); an Author who steps back and forward keeps their
              // edits.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                ref
                    .read(layerSelectionProvider.notifier)
                    .seedForModes(modes, catalog.defaultLive);
              });

              final live = selection.tripLive;
              final atDefault = setEquals(live, catalog.defaultLive);

              return Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(PlotSpacing.s6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('TRIP LAYERS', style: PlotTypography.eyebrow(c.textMuted)),
                          const SizedBox(height: PlotSpacing.s2),
                          Text('Choose what the map shows you',
                              style: PlotTypography.title(c.textPrimary)),
                          const SizedBox(height: PlotSpacing.s2),
                          Text(
                            'These are the kinds of place Plotlines looks for across the '
                            'extent you just drew — the candidates you promote a trip out of. '
                            'They start from how this trip travels; change any of them now, '
                            'or later from the Layers tab.',
                            style: PlotTypography.body(c.textSecondary),
                          ),
                          const SizedBox(height: PlotSpacing.s4),
                          // FR144/N0 AC — "the layer picker states which modes
                          // it derived its initial state from." Same phrasing
                          // as the Layers tab so the two read as one control.
                          Text(
                            'Defaults from: '
                            '${(modes.toList()..sort()).map(travelModeLabel).join(', ')}',
                            style: PlotTypography.small(c.textMuted),
                          ),
                          const SizedBox(height: PlotSpacing.s3),
                          LayerPicker(
                            layers: catalog.layers,
                            live: live,
                            layerStates: layerStates,
                            onToggle: (layer) => ref
                                .read(layerSelectionProvider.notifier)
                                .toggleTripLayer(layer),
                          ),
                          if (!atDefault) ...[
                            const SizedBox(height: PlotSpacing.s3),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: PlotButton(
                                label: 'Reset to defaults',
                                variant: PlotButtonVariant.ghost,
                                onPressed: () => ref
                                    .read(layerSelectionProvider.notifier)
                                    .setTripLive(catalog.defaultLive),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(PlotSpacing.s5),
                    decoration:
                        BoxDecoration(border: Border(top: BorderSide(color: c.border))),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          atDefault
                              ? 'Nothing to change here is fine — continue on these defaults.'
                              : 'Your selection is saved for the trip; every day can still '
                                  'override it.',
                          style: PlotTypography.small(c.textSecondary),
                        ),
                        const SizedBox(height: PlotSpacing.s3),
                        PlotButton(label: 'Continue', expand: true, onPressed: _continue),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
