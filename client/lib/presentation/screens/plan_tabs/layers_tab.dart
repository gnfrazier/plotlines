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
import '../../../domain/promote.dart'
    show DuplicatePromotionException, areaFromCandidate, provenanceFromCandidate, roleKindFromAffinity;
import '../../../state/current_trip_provider.dart';
import '../../../state/layer_selection_provider.dart';
import '../../../state/messages_provider.dart';
import '../../../state/providers.dart';
import '../../../state/trip_bbox_provider.dart';
import '../../../state/trip_candidates_provider.dart';
import '../../map/anchor_map_points.dart';
import '../../map/candidate_map.dart';
import '../../widgets/desktop_error_surface.dart';
import '../../widgets/layer_picker.dart';
import '../../widgets/teaching_block.dart';
import '../../../data/curation_client.dart' show LayerCatalog;
import 'proposals_view.dart';
import 'route_tab.dart' show routeTabMarkerPoints;

const _uuid = Uuid();

class LayersTab extends ConsumerStatefulWidget {
  const LayersTab({super.key, required this.trip, required this.activeDayId});
  final Trip trip;
  final String? activeDayId;

  @override
  ConsumerState<LayersTab> createState() => _LayersTabState();
}

class _LayersTabState extends ConsumerState<LayersTab> {
  // Issue #316 — the candidate list, its loading flag and its last error
  // moved to `tripCandidatesProvider` so the set the trip-creation layer
  // step warms is the same one this tab shows. The "Find candidates here"
  // button re-runs it; nothing here fetches on entry.
  _CurationView _view = _CurationView.candidates;

  Day? get _activeDay =>
      widget.trip.days.where((d) => d.id == widget.activeDayId).firstOrNull;

  /// FR144/N0, #319 — the trip's one mode set feeds the layer picker's
  /// defaults directly. No fallback chain: the set is the single source of
  /// truth and every segment's mode is in it (`Trip.modes`); a pre-#319 row
  /// had its two columns folded by the v6 migration. `layerModesKey` still
  /// maps an empty set (a day-less trip saved before N0) to cycling for the
  /// fetch.
  Set<String> get _effectiveModes => widget.trip.modes;

  String get _dayType => _activeDay?.kind ?? 'route';

  @override
  Widget build(BuildContext context) {
    final day = _activeDay;
    final modes = _effectiveModes;
    final catalogKey = (modes: layerModesKey(modes), dayType: _dayType);
    final catalogAsync = ref.watch(layerCatalogProvider(catalogKey));
    final selection = ref.watch(layerSelectionProvider);

    return catalogAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      // Issue #317 — a `/layers` failure is M13's `layerExtractionFailed`
      // state (the curation capability is what this tab is a surface for),
      // routed through the one shared desktop error surface: a headline, a
      // cause phrase from the bounded table, and a Retry that re-runs the
      // fetch. `err` (a `CurationException`) never reaches the screen —
      // its `toString()` is the class name, the status code and the raw
      // response body, which is exactly what M13 exists to keep out of the UI.
      error: (err, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(PlotSpacing.s6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: DesktopErrorSurface(
              state: DesktopErrorState.layerExtractionFailed,
              content: DesktopErrorContent(
                headline: 'The trip layers didn\'t load',
                why: ref.watch(messagesProvider).reason(ReasonCode.layerExtractionFailed),
                onRetry: () => ref.invalidate(layerCatalogProvider(catalogKey)),
              ),
            ),
          ),
        ),
      ),
      data: (catalog) {
        // FR144/N0 — reseeds only when the mode set actually changed
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
    final candidatesState = ref.watch(tripCandidatesProvider);
    final layerStates =
        ref.watch(sidecarManagerProvider).capabilities?.layersPerLayer ?? const {};
    // #477 — "promoted for this day" is now an anchor attachment (any role
    // with `dayId == day.id`), not `day.nodes`: `_promote` below writes an
    // Anchor, and attachment is a role property (FR142b, K12 / N4a), not a
    // day-owned list.
    final dayAnchors = day == null
        ? const <Anchor>[]
        : widget.trip.anchors.where((a) => a.roles.any((r) => r.dayId == day.id)).toList();
    return Row(
          children: [
            Expanded(
              child: Stack(
                children: [
                  CandidateMap(
                      candidates: candidatesState.candidates,
                      bbox: bbox,
                      // #410 — what has already been promoted, drawn as
                      // such: anchors from the proposals view / Content
                      // tab, and the day nodes `_promote` below writes.
                      anchors: anchorMapPoints(widget.trip.anchors),
                      nodes: routeTabMarkerPoints(widget.trip),
                      onCandidateTap: _promote),
                  Positioned(
                    top: PlotSpacing.s3,
                    left: PlotSpacing.s3,
                    child: _FindCandidatesButton(
                      enabled: bbox != null && !candidatesState.loading,
                      loading: candidatesState.loading,
                      onPressed: () => _fetchCandidates(live),
                    ),
                  ),
                  if (candidatesState.error != null)
                    Positioned(
                      bottom: PlotSpacing.s3,
                      left: PlotSpacing.s3,
                      right: PlotSpacing.s3,
                      child: _ErrorBanner(message: candidatesState.error!),
                    )
                  else if (candidatesState.layersUnavailable.isNotEmpty)
                    Positioned(
                      bottom: PlotSpacing.s3,
                      left: PlotSpacing.s3,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
                        child: _unavailableLayersSurface(candidatesState, live),
                      ),
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
                    Text('Promoted (${dayAnchors.length})',
                        style: PlotTypography.title(c.textPrimary)),
                    const SizedBox(height: PlotSpacing.s2),
                    if (day == null || dayAnchors.isEmpty)
                      Text('Tap a candidate on the map to promote it.',
                          style: PlotTypography.body(c.textMuted))
                    else
                      Wrap(
                        spacing: PlotSpacing.s2,
                        runSpacing: PlotSpacing.s2,
                        children: [
                          for (final anchor in dayAnchors)
                            PlotBadge(anchor.title ?? anchor.provenance?.layer ?? 'Untitled'),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
  }

  /// #400 / #415 — `GET /candidates` served some of the live layers and not
  /// others (or none of them, through a 200 rather than an exception). The
  /// candidates that did arrive stay on the map; this card sits beside
  /// them, names each missing layer with a bounded cause, and retries just
  /// those. With nothing served it is `layerExtractionFailed` — the total
  /// case — and the retry is the whole run.
  Widget _unavailableLayersSurface(TripCandidatesState candidatesState, Set<String> live) {
    final messages = ref.watch(messagesProvider);
    final partial = candidatesState.isPartiallyServed;
    final state = partial
        ? DesktopErrorState.layersPartiallyServed
        : DesktopErrorState.layerExtractionFailed;
    final details = [
      for (final entry in candidatesState.layersUnavailable.entries)
        messages.resolve(MessageId.layerUnavailableBecause, {
          'layer': NameSlot(layerLabels[entry.key] ?? entry.key, source: NameSource.layerName),
          'reason': ReasonSlot(unavailableLayerReason(entry.value)),
        }),
    ];
    return DesktopErrorSurface(
      state: state,
      content: DesktopErrorContent(
        headline: partial ? 'Some layers are missing' : 'The candidates didn\'t load',
        why: messages.reason(desktopErrorTreatments[state]!.reason),
        details: details,
        whatStillWorks: [
          if (partial) ...[
            messages.resolve(MessageId.candidateCount,
                {'count': CountSlot(candidatesState.candidates.length)}),
            messages.resolve(MessageId.layersOnMap, {
              'layers': NameListSlot(
                  [for (final l in candidatesState.layersServed) layerLabels[l] ?? l],
                  source: NameSource.layerName),
            }),
          ],
        ],
        retryLabel: partial ? 'Retry those layers' : 'Retry',
        onRetry: partial
            ? () => ref.read(tripCandidatesProvider.notifier).retryUnavailable()
            : () => _fetchCandidates(live),
      ),
    );
  }

  void _fetchCandidates(Set<String> liveLayers) {
    final bbox = ref.read(tripBboxProvider);
    if (bbox == null) return;
    ref.read(tripCandidatesProvider.notifier).fetch(bbox: bbox, liveLayers: liveLayers);
  }

  /// FR99 — "an Author can promote any candidate directly [...] without
  /// ever running N4." No proposal, no cluster review: a tap is the whole
  /// interaction.
  ///
  /// #477 — this used to append a day-scoped `Node` (`promoteCandidate`,
  /// N3's stand-in from before O1's Anchor/role model existed). It now goes
  /// through the same `promoteAnchor` path as the proposals view and the
  /// hand-placed dialog: one role, pre-filled from the candidate's affinity
  /// (`roleKindFromAffinity`) and attached to the active day directly
  /// (`dayId: day.id`) since a tap here already names the day it's for,
  /// geometry/provenance copied from the candidate (`areaFromCandidate` /
  /// `provenanceFromCandidate`, #403's O3 seam). `DuplicatePromotionException`
  /// is caught the way `proposals_view.dart` does — re-tapping an
  /// already-promoted candidate routes the Author to editing it instead of
  /// silently duplicating the anchor (FR106).
  void _promote(Candidate candidate) {
    final day = _activeDay;
    if (day == null) return;
    final roles = [
      Role(
        id: _uuid.v4(),
        kind: roleKindFromAffinity(candidate.roleAffinity),
        dayId: day.id,
      ),
    ];
    try {
      final anchor = ref.read(currentTripProvider.notifier).promoteAnchor(
            coord: candidate.coord,
            roles: roles,
            title: candidate.title,
            area: areaFromCandidate(candidate),
            provenance: provenanceFromCandidate(candidate),
          );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Promoted "${anchor.title ?? candidate.layer}"')),
      );
    } on DuplicatePromotionException {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Already promoted — edit its roles in the Anchors view')),
      );
    }
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

  void _attach(String anchorId, String roleId, {required String dayId, String? segmentId}) {
    ref.read(currentTripProvider.notifier).updateRole(
          anchorId,
          roleId,
          dayId: dayId,
          segmentId: segmentId,
        );
  }

  void _detach(String anchorId, String roleId) {
    ref.read(currentTripProvider.notifier).updateRole(anchorId, roleId, clearDayId: true);
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

    // FR142b, K12 / N4a (issue #384) — attachment is [Role.dayId], a real
    // structural link, never a title guess: an anchor is attached when any
    // one of its roles carries a day.
    final rows = [
      for (final a in anchors)
        (anchor: a, attached: a.roles.any((role) => role.dayId != null)),
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
          padding: const EdgeInsets.fromLTRB(
              PlotSpacing.s3, PlotSpacing.s3, PlotSpacing.s3, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('ANCHORS', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: PlotSpacing.s1),
              const TeachingHelpIcon(moment: TeachingMoment.promotionNotIntoDay),
            ],
          ),
        ),
        // K12a — promoting a candidate parks it here; it still needs placing
        // into a day, which this view's own attached/unattached split makes
        // visible but does not itself explain.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3),
          child: TeachingBlock(tripId: widget.trip.id, moment: TeachingMoment.promotionNotIntoDay),
        ),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.anchor.title ?? 'Untitled anchor',
                        style: PlotTypography.title(c.textPrimary)),
                    const SizedBox(height: PlotSpacing.s2),
                    // Attachment is a role property (FR106 — roles are
                    // independent), so it's shown and set per role, never
                    // rolled up to one anchor-wide status. A plain status
                    // line, never an error badge on the unattached ones.
                    for (final role in r.anchor.roles)
                      Padding(
                        padding: const EdgeInsets.only(top: PlotSpacing.s1),
                        child: _RoleAttachRow(
                          trip: widget.trip,
                          role: role,
                          onAttach: (dayId, segmentId) =>
                              _attach(r.anchor.id, role.id, dayId: dayId, segmentId: segmentId),
                          onDetach: () => _detach(r.anchor.id, role.id),
                        ),
                      ),
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

/// FR142b, K12 / N4a (issue #384) — one role's attachment status, plus the
/// attach/detach affordance that makes an unattached anchor **re-attachable**
/// (N4a's own AC), not merely findable. Attachment is [Role.dayId] /
/// [Role.segmentId] — a real structural link set here, never inferred from a
/// title match.
class _RoleAttachRow extends StatelessWidget {
  const _RoleAttachRow({
    required this.trip,
    required this.role,
    required this.onAttach,
    required this.onDetach,
  });

  final Trip trip;
  final Role role;
  final void Function(String dayId, String? segmentId) onAttach;
  final VoidCallback onDetach;

  Day? get _attachedDay =>
      role.dayId == null ? null : trip.days.where((d) => d.id == role.dayId).firstOrNull;

  Segment? get _attachedSegment {
    final day = _attachedDay;
    if (day == null || role.segmentId == null) return null;
    return day.segments.where((s) => s.id == role.segmentId).firstOrNull;
  }

  String _dayLabel(Day day) => day.title == null ? 'Day ${day.index}' : 'Day ${day.index} — ${day.title}';

  String _segmentLabel(Segment s) => s.title ?? travelModeLabel(s.mode);

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final day = _attachedDay;
    final segment = _attachedSegment;
    final statusText = day == null
        ? 'Unattached'
        : (segment == null ? _dayLabel(day) : '${_dayLabel(day)} · ${_segmentLabel(segment)}');

    return Row(
      children: [
        PlotBadge(role.kind.name.toUpperCase()),
        const SizedBox(width: PlotSpacing.s2),
        Expanded(child: Text(statusText, style: PlotTypography.small(c.textMuted))),
        PopupMenuButton<void>(
          tooltip: day == null ? 'Attach to a day' : 'Change attachment',
          icon: Icon(Icons.link, size: 18, color: c.textMuted),
          itemBuilder: (_) => [
            for (final d in trip.days) ...[
              PopupMenuItem<void>(
                child: Text(_dayLabel(d)),
                onTap: () => onAttach(d.id, null),
              ),
              for (final s in d.segments)
                PopupMenuItem<void>(
                  child: Padding(
                    padding: const EdgeInsets.only(left: PlotSpacing.s3),
                    child: Text('${_dayLabel(d)} · ${_segmentLabel(s)}'),
                  ),
                  onTap: () => onAttach(d.id, s.id),
                ),
            ],
            if (day != null) ...[
              const PopupMenuDivider(),
              PopupMenuItem<void>(onTap: onDetach, child: const Text('Detach')),
            ],
          ],
        ),
      ],
    );
  }
}
