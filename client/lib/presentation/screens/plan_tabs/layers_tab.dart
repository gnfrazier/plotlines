// Story N3 (FR97/FR98/FR99) — the curation workspace: which data layers are
// live (trip-wide, overridable per day), candidates ranked by salience on
// the planning map, and direct promotion — an Author can complete a whole
// trip from here without ever running co-location analysis (N4, not built;
// this tab's promote action is the only write path curation has into the
// trip, matching ARCH P10).
//
// Layout mirrors `content_tab.dart`'s map-left/panel-right split rather than
// inventing a new one — this workspace didn't have a wireframe yet
// (`Plotlines_MVP_Redirection_Punchlist.md` §5.2 says so explicitly), so it
// reuses the one screen shape this Trip Shell already has for "map plus a
// curated-content rail."
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:uuid/uuid.dart';

import '../../../domain/candidate.dart';
import '../../../domain/domain.dart';
import '../../../state/current_trip_provider.dart';
import '../../../state/layer_selection_provider.dart';
import '../../../state/providers.dart';
import '../../../state/trip_bbox_provider.dart';
import '../../map/candidate_map.dart';
import '../../widgets/layer_picker.dart';

const _uuid = Uuid();

class LayersTab extends ConsumerStatefulWidget {
  const LayersTab({super.key, required this.trip, required this.activeDayId});
  final Trip trip;
  final String? activeDayId;

  @override
  ConsumerState<LayersTab> createState() => _LayersTabState();
}

class _LayersTabState extends ConsumerState<LayersTab> {
  List<Candidate> _candidates = const [];
  bool _loading = false;
  String? _error;

  Day? get _activeDay =>
      widget.trip.days.where((d) => d.id == widget.activeDayId).firstOrNull;

  /// FR144/N0 — the trip's declared modes now feed the layer picker's
  /// defaults directly. A trip saved before N0 (nothing in `declaredModes`
  /// yet, `app_database.dart`'s migration note) falls back to whatever
  /// modes are actually realized in its segments, and finally to cycling
  /// for a brand-new, day-less trip — the same fallback chain
  /// `Trip.modes`'s own doc comment already draws a line under.
  Set<String> get _effectiveModes {
    if (widget.trip.declaredModes.isNotEmpty) return widget.trip.declaredModes;
    if (widget.trip.modes.isNotEmpty) return widget.trip.modes;
    return const {'cycling'};
  }

  String get _dayType => _activeDay?.kind ?? 'route';

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final day = _activeDay;
    final modes = _effectiveModes;
    final catalogAsync =
        ref.watch(layerCatalogProvider((modes: layerModesKey(modes), dayType: _dayType)));
    final selection = ref.watch(layerSelectionProvider);
    final bbox = ref.watch(tripBboxProvider);
    // Per-layer readiness (ARCH §8.3, story N2). Empty for the six built-in
    // OSM layers; a plugin dataset (N5) reports `loading`/`failed` here and
    // the picker disables just that chip, never the workspace.
    final layerStates =
        ref.watch(sidecarManagerProvider).capabilities?.layersPerLayer ?? const {};

    return catalogAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(PlotSpacing.s6),
          child: Text('Could not load the layer catalog: $err',
              style: PlotTypography.body(c.danger), textAlign: TextAlign.center),
        ),
      ),
      data: (catalog) {
        // FR144/N0 — reseeds only when the declared set actually changed
        // since the last seed (`seedForModes`'s own doc comment); switching
        // the active day (and so `_dayType`) alone never re-triggers this.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(layerSelectionProvider.notifier).seedForModes(modes, catalog.defaultLive);
        });
        final live = selection.liveFor(day?.id);

        return Row(
          children: [
            Expanded(
              child: Stack(
                children: [
                  CandidateMap(candidates: _candidates, bbox: bbox, onCandidateTap: _promote),
                  Positioned(
                    top: PlotSpacing.s3,
                    left: PlotSpacing.s3,
                    child: _FindCandidatesButton(
                      enabled: bbox != null && !_loading,
                      loading: _loading,
                      onPressed: () => _fetchCandidates(live),
                    ),
                  ),
                  if (_error != null)
                    Positioned(
                      bottom: PlotSpacing.s3,
                      left: PlotSpacing.s3,
                      right: PlotSpacing.s3,
                      child: _ErrorBanner(message: _error!),
                    ),
                ],
              ),
            ),
            Container(
              width: 380,
              decoration: BoxDecoration(border: Border(left: BorderSide(color: c.border))),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(PlotSpacing.s4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Trip layers', style: PlotTypography.title(c.textPrimary)),
                    const SizedBox(height: PlotSpacing.s1),
                    // FR144/N0 AC — "the layer picker states which modes it
                    // derived its initial state from."
                    Text(
                      'Defaults from: ${(modes.toList()..sort()).map(travelModeLabel).join(', ')}',
                      style: PlotTypography.small(c.textMuted),
                    ),
                    const SizedBox(height: PlotSpacing.s3),
                    LayerPicker(
                      layers: catalog.layers,
                      live: selection.tripLive,
                      layerStates: layerStates,
                      onToggle: (layer) =>
                          ref.read(layerSelectionProvider.notifier).toggleTripLayer(layer),
                    ),
                    if (day != null) ...[
                      const SizedBox(height: PlotSpacing.s5),
                      Row(
                        children: [
                          Expanded(
                            child: Text('${day.title ?? 'This day'}\'s override',
                                style: PlotTypography.title(c.textPrimary)),
                          ),
                          if (selection.hasOverride(day.id))
                            TextButton(
                              onPressed: () => ref
                                  .read(layerSelectionProvider.notifier)
                                  .clearDayOverride(day.id),
                              child: const Text('Use trip default'),
                            ),
                        ],
                      ),
                      const SizedBox(height: PlotSpacing.s2),
                      if (selection.hasOverride(day.id))
                        LayerPicker(
                          layers: catalog.layers,
                          live: live,
                          layerStates: layerStates,
                          onToggle: (layer) => ref
                              .read(layerSelectionProvider.notifier)
                              .toggleDayLayer(day.id, layer),
                        )
                      else
                        Wrap(
                          spacing: PlotSpacing.s2,
                          runSpacing: PlotSpacing.s2,
                          children: [
                            for (final layer in live)
                              PlotBadge(layerLabels[layer] ?? layer),
                            TextButton(
                              onPressed: () => ref
                                  .read(layerSelectionProvider.notifier)
                                  .setDayOverride(day.id, live),
                              child: const Text('Override for this day'),
                            ),
                          ],
                        ),
                    ],
                    const SizedBox(height: PlotSpacing.s5),
                    Text('Promoted (${day?.nodes.length ?? 0})',
                        style: PlotTypography.title(c.textPrimary)),
                    const SizedBox(height: PlotSpacing.s2),
                    if (day == null || day.nodes.isEmpty)
                      Text('Tap a candidate on the map to promote it.',
                          style: PlotTypography.body(c.textMuted))
                    else
                      Wrap(
                        spacing: PlotSpacing.s2,
                        runSpacing: PlotSpacing.s2,
                        children: [
                          for (final node in day.nodes)
                            PlotBadge(node.title ?? node.poiType ?? node.kind.wireValue),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _fetchCandidates(Set<String> liveLayers) async {
    final bbox = ref.read(tripBboxProvider);
    if (bbox == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final candidates = await ref
          .read(curationClientProvider)
          .candidatesForBbox(bbox: bbox, liveLayers: liveLayers);
      if (!mounted) return;
      setState(() => _candidates = candidates);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// FR99 — "an Author can promote any candidate directly [...] without
  /// ever running N4." No proposal, no cluster review: a tap is the whole
  /// interaction.
  void _promote(Candidate candidate) {
    final day = _activeDay;
    if (day == null) return;
    final node = Node(
      id: _uuid.v4(),
      kind: NodeKind.poi,
      coord: candidate.coord,
      title: candidate.title,
      poiType: candidate.layer,
    );
    ref.read(currentTripProvider.notifier).promoteCandidate(day.id, node);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Promoted "${node.title ?? node.poiType}"')),
    );
  }
}

class _FindCandidatesButton extends StatelessWidget {
  const _FindCandidatesButton({required this.enabled, required this.loading, required this.onPressed});
  final bool enabled;
  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
      decoration: BoxDecoration(
        color: c.surfaceCard.withValues(alpha: 0.92),
        borderRadius: PlotRadii.controlShape,
        border: Border.all(color: c.border),
      ),
      child: loading
          ? const SizedBox(
              width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : InkWell(
              onTap: enabled ? onPressed : null,
              child: Text(
                enabled ? 'Find candidates here' : 'Draw a trip area to find candidates',
                style: PlotTypography.data(enabled ? c.textPrimary : c.textMuted),
              ),
            ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
      decoration: BoxDecoration(
        color: c.surfaceCard.withValues(alpha: 0.95),
        borderRadius: PlotRadii.controlShape,
        border: Border.all(color: c.danger),
      ),
      child: Text(message, style: PlotTypography.data(c.danger)),
    );
  }
}
