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
import '../../../data/curation_client.dart' show LayerCatalog;
import 'proposals_view.dart';

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
  _CurationView _view = _CurationView.candidates;

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

        // PRD §5.4a / N4a — "the workspace carries three views over the same
        // bbox: candidates, proposals, and anchors."
        final Widget viewBody = switch (_view) {
          _CurationView.candidates => _candidatesView(context, catalog, live, day),
          _CurationView.proposals => ProposalsView(trip: widget.trip, liveLayers: live),
          _CurationView.anchors => AnchorsView(trip: widget.trip),
        };

        return Column(
          children: [
            _CurationViewSwitcher(
              value: _view,
              anchorCount: widget.trip.anchors.length,
              onChanged: (v) => setState(() => _view = v),
            ),
            const Divider(height: 1),
            Expanded(child: viewBody),
          ],
        );
      },
    );
  }

  Widget _candidatesView(BuildContext context, LayerCatalog catalog, Set<String> live, Day? day) {
    final c = PlotColors.of(context);
    final selection = ref.watch(layerSelectionProvider);
    final bbox = ref.watch(tripBboxProvider);
    final modes = _effectiveModes;
    final layerStates =
        ref.watch(sidecarManagerProvider).capabilities?.layersPerLayer ?? const {};
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

/// PRD §5.4a / N4a — the three views the curation workspace carries over the
/// same bbox.
enum _CurationView { candidates, proposals, anchors }

class _CurationViewSwitcher extends StatelessWidget {
  const _CurationViewSwitcher({
    required this.value,
    required this.anchorCount,
    required this.onChanged,
  });

  final _CurationView value;
  final int anchorCount;
  final ValueChanged<_CurationView> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(PlotSpacing.s3),
      child: SegmentedButton<_CurationView>(
        segments: [
          const ButtonSegment(value: _CurationView.candidates, label: Text('Candidates')),
          const ButtonSegment(value: _CurationView.proposals, label: Text('Proposals')),
          ButtonSegment(
            value: _CurationView.anchors,
            label: Text(anchorCount == 0 ? 'Anchors' : 'Anchors ($anchorCount)'),
          ),
        ],
        selected: {value},
        showSelectedIcon: false,
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}

/// N4a — the anchors view: what has been promoted, filterable by attachment.
/// **Unattached anchors are ordinary working state, not a problem queue** —
/// not badged, not counted as errors, never blocking anything (Q2).
class AnchorsView extends ConsumerStatefulWidget {
  const AnchorsView({super.key, required this.trip});
  final Trip trip;

  @override
  ConsumerState<AnchorsView> createState() => _AnchorsViewState();
}

enum _AttachFilter { all, attached, unattached }

class _AnchorsViewState extends ConsumerState<AnchorsView> {
  _AttachFilter _filter = _AttachFilter.all;

  /// An anchor is "attached" if any day's node carries its id as a POI type
  /// hint or title match — best-effort on this build, where passages do not
  /// yet reference anchor ids directly.
  bool _isAttached(String anchorId, String? title) {
    for (final day in widget.trip.days) {
      for (final node in day.nodes) {
        if (node.title != null && title != null && node.title == title) return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final anchors = widget.trip.anchors;
    if (anchors.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(PlotSpacing.s6),
          child: Text(
            'Nothing promoted yet. Promote a candidate or a proposal to park a '
            'place here — an anchor can sit unattached to any day, which is '
            'ordinary working state, not a problem.',
            style: PlotTypography.body(c.textMuted),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final rows = [
      for (final a in anchors)
        (anchor: a, attached: _isAttached(a.id, a.title)),
    ];
    final filtered = switch (_filter) {
      _AttachFilter.all => rows,
      _AttachFilter.attached => rows.where((r) => r.attached).toList(),
      _AttachFilter.unattached => rows.where((r) => !r.attached).toList(),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(PlotSpacing.s3),
          child: Wrap(
            spacing: PlotSpacing.s2,
            children: [
              for (final f in _AttachFilter.values)
                ChoiceChip(
                  label: Text(switch (f) {
                    _AttachFilter.all => 'All',
                    _AttachFilter.attached => 'Attached',
                    _AttachFilter.unattached => 'Unattached',
                  }),
                  selected: _filter == f,
                  onSelected: (_) => setState(() => _filter = f),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(PlotSpacing.s3),
            itemCount: filtered.length,
            separatorBuilder: (_, _) => const SizedBox(height: PlotSpacing.s2),
            itemBuilder: (context, i) {
              final r = filtered[i];
              return PlotCard(
                padding: const EdgeInsets.all(PlotSpacing.s3),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r.anchor.title ?? 'Untitled anchor',
                              style: PlotTypography.title(c.textPrimary)),
                          const SizedBox(height: PlotSpacing.s1),
                          Text(
                            r.anchor.roles.map((role) => role.kind.name).join(' · ').toUpperCase(),
                            style: PlotTypography.data(c.textMuted),
                          ),
                        ],
                      ),
                    ),
                    // Attachment is shown as a plain status, never as an error
                    // badge on the unattached ones.
                    Text(r.attached ? 'attached' : 'unattached',
                        style: PlotTypography.small(c.textMuted)),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
