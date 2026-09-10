// Wireframe screen "01 Route Planner" — the Trip Shell's Route tab: the
// always-visible weights rail (`weights_rail.dart`), the map + day timeline
// strip (`day_timeline_strip.dart`), replacing the old standalone
// `route_planner_screen.dart` (deleted) which used a day/segment list
// instead of the wireframe's map-first canvas.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../../data/sidecar_manager.dart' show CapabilityStatus;
import '../../../domain/domain.dart';
import '../../../state/current_trip_provider.dart';
import '../../../state/planner_ui_state.dart';
import '../../../state/providers.dart';
import '../../../state/settings_provider.dart';
import '../../map/alternate_markers.dart';
import '../../map/node_marker_role.dart';
import '../../map/route_geometry.dart';
import '../../map/tap_to_pick_map.dart';
import '../../widgets/alternate_draft_bar.dart';
import '../../widgets/alternate_editor_dialog.dart';
import '../../widgets/day_timeline_strip.dart';
import '../../widgets/metrics_rail.dart';
import '../../widgets/node_editor_sheet.dart';
import '../../widgets/weights_rail.dart';

/// Every day's segment endpoints plus every authored node, each tagged with
/// the role it plays: a segment's `start` begins a day, its `end` finishes one
/// (#320), and an authored `Node` draws as the mark its `kind` implies
/// (`node_marker_role.dart`, #322). The mark is chosen from that role, never
/// from the point's position in a concatenated list — so on a multi-day trip
/// *every* day's start is a `start`, not just day 1's, and a lone endpoint is
/// not both the first and last index at once.
///
/// Before #322 authored nodes were saved, exported and itemised but never
/// reached the map at all: `Segment.nodes` and `Day.nodes` were simply not
/// read here.
List<MapMarkerPoint> routeTabMarkerPoints(Trip trip) => [
      for (final d in trip.days) ...[
        for (final s in d.segments) ...[
          if (s.start != null) (coord: s.start!, role: NodeMarkerType.start),
          if (s.end != null) (coord: s.end!, role: NodeMarkerType.finish),
          for (final n in s.nodes)
            (coord: n.coord, role: markerForNodeKind(n.kind)),
        ],
        // Day-scoped nodes — a rest day's POIs and scheduled events, which no
        // segment owns.
        for (final n in d.nodes)
          (coord: n.coord, role: markerForNodeKind(n.kind)),
      ],
    ];

/// #322 — a node closer to the line than this is effectively *on* it; a leader
/// line would be a nub. Farther than [kLeaderLineMaxM] it reads as its own
/// place rather than an offset from the day's line, and a dashed line drawn
/// clear across the map is noise, not information — so no connector either way.
const double kLeaderLineMinM = 4;
const double kLeaderLineMaxM = 750;

/// #322 — connectors from the selected segment's off-route nodes to their
/// nearest point on its solved geometry. Empty until there is a line to
/// measure against.
List<MapLeaderLine> routeTabLeaderLines(Segment? segment) {
  final geom = segment?.geometry?.coordinates;
  if (geom == null || geom.length < 2) return const [];
  final out = <MapLeaderLine>[];
  for (final n in segment!.nodes) {
    final near = nearestPointOnPath(geom, n.coord);
    if (near == null) continue;
    if (near.distanceM < kLeaderLineMinM || near.distanceM > kLeaderLineMaxM) {
      continue;
    }
    out.add((from: n.coord, to: near.point));
  }
  return out;
}

/// #322 — the coordinate of the node [selectedNodeIdProvider] names, scanning
/// segment and day nodes; `null` when nothing is selected or the id is stale.
LatLonPoint? nodeCoordById(Trip trip, String? nodeId) {
  if (nodeId == null) return null;
  for (final d in trip.days) {
    for (final s in d.segments) {
      for (final n in s.nodes) {
        if (n.id == nodeId) return n.coord;
      }
    }
    for (final n in d.nodes) {
      if (n.id == nodeId) return n.coord;
    }
  }
  return null;
}

class RouteTab extends ConsumerStatefulWidget {
  const RouteTab({super.key, required this.trip, required this.activeDayId, required this.onSelectDay});
  final Trip trip;
  final String? activeDayId;
  final ValueChanged<String> onSelectDay;

  @override
  ConsumerState<RouteTab> createState() => _RouteTabState();
}

class _RouteTabState extends ConsumerState<RouteTab> {
  bool _addingNode = false;

  /// #324 — the divergence being drawn, and the passage it is being drawn on.
  /// Alternate creation *starts* here, on the map, on a day that already has a
  /// route: the Author marks the fork and the rejoin (and shapes the path
  /// between them if they want to), and only then is anything named. The card
  /// that opens afterwards describes a path that exists.
  AlternateDraft? _altDraft;
  (String dayId, String segmentId)? _altDraftOn;

  /// Selecting a different passage abandons a half-drawn divergence: a fork
  /// measured along one line means nothing on another. Nothing authored is
  /// lost — the draft has not reached the trip yet.
  void _syncDraftToSelection((String, String)? selected) {
    if (_altDraft == null) return;
    if (_altDraftOn == null || selected == null || _altDraftOn != selected) {
      _altDraft = null;
      _altDraftOn = null;
    }
  }

  Future<void> _createAlternate(AlternateDraft draft, String dayId, String segmentId) async {
    final naming = await showAlternateNamingDialog(context, draft: draft);
    // Backing out of naming keeps the draft: the Author may still be drawing.
    if (naming == null) return;
    final made = ref.read(currentTripProvider.notifier).addAlternateToSegment(
          dayId,
          segmentId,
          intent: naming.intent,
          kind: naming.kind,
          label: naming.label,
          geometry: draft.geometry!,
          divergesAtM: draft.divergesAtM,
          rejoinsAtM: draft.rejoinsAtM,
        );
    setState(() {
      _altDraft = null;
      _altDraftOn = null;
    });
    if (!mounted) return;
    await showAlternateCard(
      context,
      dayId: dayId,
      segmentId: segmentId,
      alternateId: made.id,
    );
  }

  /// FR121/N2 — same "no trip-wide flag" reading `new_route_screen.dart`'s
  /// `_routingCapability` uses: before the sidecar has answered `/health`
  /// even once this is an honest wait, not a bare "not ready".
  CapabilityStatus get _elevationCapability =>
      ref.watch(sidecarManagerProvider).capabilities?.elevation ??
      const CapabilityStatus(ready: false, reason: 'waiting for the sidecar');

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final selected = ref.watch(selectedSegmentProvider);
    final selectedSegment = resolveSelectedSegment(widget.trip, selected)?.$2;
    final railDayId = selected?.$1 ?? widget.activeDayId ?? '';

    // E3 / FR39 / FR117 / FR118 (issue #214) — the compose-mode places-first
    // itinerary for the day the rail is showing, when that day is in compose
    // mode. `composeAuthoritative` fills the provider on save; it stays null in
    // explore mode and until the first authoritative pass.
    final composeItinerary =
        ref.watch(dayPlanningModeProvider(railDayId)) == PlanningMode.compose
            ? ref.watch(composeItineraryProvider(railDayId))
            : null;

    // #322 — the node just saved/selected: the map pans to it and draws it
    // highlighted so the Author sees the thing they made.
    final focusCoord =
        nodeCoordById(widget.trip, ref.watch(selectedNodeIdProvider));

    _syncDraftToSelection(selected);
    final draft = _altDraft;
    final routeCoords = selectedSegment?.geometry?.coordinates;
    // #324 — a passage with no solved line has nothing to diverge from, so
    // the gesture is not offered rather than offered and then refused.
    final canDraftAlternate = selected != null && AlternateDraft.canDraftOn(routeCoords);

    return Row(
      children: [
        WeightsRail(dayId: railDayId, segment: selectedSegment),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    TapToPickMap(
                      points: routeTabMarkerPoints(widget.trip),
                      polyline: routeCoords ?? const [],
                      leaderLines: routeTabLeaderLines(selectedSegment),
                      // #324 — the divergence as it is being drawn: the path
                      // dashed, the stretch of the day it stands in for cased
                      // underneath, and a mark at each end.
                      draftLine: draft?.previewLine ?? const [],
                      replacedStretch: draft?.canonStretch ?? const [],
                      annotations: [
                        if (draft?.leavesPoint != null)
                          (
                            coord: draft!.leavesPoint!,
                            marker: const AlternateEndpointMarker(AlternateEndpoint.fork),
                          ),
                        if (draft?.rejoinsPoint != null)
                          (
                            coord: draft!.rejoinsPoint!,
                            marker: const AlternateEndpointMarker(AlternateEndpoint.rejoin),
                          ),
                      ],
                      focusCoord: focusCoord,
                      onTap: draft != null
                          ? (point) => setState(() => _altDraft = draft.tap(point))
                          : (!_addingNode || selected == null)
                              ? null
                              : (point) async {
                                  setState(() => _addingNode = false);
                                  final saved = await showNodeEditorSheet(
                                    context,
                                    dayId: selected.$1,
                                    segmentId: selected.$2,
                                    coord: point,
                                    routeGeometry: routeCoords,
                                  );
                                  // #322 — select and reveal the node just placed.
                                  if (saved != null) {
                                    ref.read(selectedNodeIdProvider.notifier).state =
                                        saved.id;
                                  }
                                },
                    ),
                    if (draft != null)
                      Positioned(
                        top: PlotSpacing.s3,
                        right: PlotSpacing.s3,
                        child: AlternateDraftBar(
                          draft: draft,
                          displayFormat: ref.watch(displayFormatProvider),
                          onUndo: draft.fork == null
                              ? null
                              : () => setState(() => _altDraft = draft.undoLast()),
                          onCancel: () => setState(() {
                            _altDraft = null;
                            _altDraftOn = null;
                          }),
                          onCreate: draft.isComplete
                              ? () => _createAlternate(
                                  draft, _altDraftOn!.$1, _altDraftOn!.$2)
                              : null,
                        ),
                      )
                    else if (selected != null)
                      Positioned(
                        top: PlotSpacing.s3,
                        right: PlotSpacing.s3,
                        child: Row(
                          children: [
                            if (canDraftAlternate)
                              PlotButton(
                                label: 'Add alternate',
                                icon: Icons.alt_route,
                                variant: PlotButtonVariant.secondary,
                                onPressed: () => setState(() {
                                  _addingNode = false;
                                  _altDraft = AlternateDraft.on(routeCoords!);
                                  _altDraftOn = selected;
                                }),
                              ),
                            const SizedBox(width: PlotSpacing.s2),
                            PlotButton(
                              label: _addingNode ? 'Tap map to place node…' : 'Add node',
                              icon: Icons.add_location_alt_outlined,
                              variant: _addingNode
                                  ? PlotButtonVariant.secondary
                                  : PlotButtonVariant.primary,
                              onPressed: () => setState(() => _addingNode = !_addingNode),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Divider(height: 1, color: c.border),
              DayTimelineStrip(
                trip: widget.trip,
                activeDayId: widget.activeDayId,
                onSelectDay: widget.onSelectDay,
              ),
            ],
          ),
        ),
        MetricsRail(
          trip: widget.trip,
          selectedSegment: selectedSegment,
          elevationCapability: _elevationCapability,
          composeItinerary: composeItinerary,
          displayFormat: ref.watch(displayFormatProvider),
        ),
      ],
    );
  }
}
