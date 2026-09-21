// FR99 — candidates on the planning map, salience rendered as size/weight/
// opacity (`CandidateMarker`, plotlines_ui). Reuses `MapTileAssets`
// (tap_to_pick_map.dart's once-per-run tile/theme cache) rather than
// duplicating that loading logic, the same way `trip_area_map.dart` does for
// N1's bbox-drawing map — this is a sibling map widget, not a variant of
// `TapToPickMap`, because candidates need per-marker taps (promote) and
// salience-scaled rendering that `TapToPickMap`'s fixed `NodeMarkerType`
// point list has no way to express.
library;

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/material.dart' as material show Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

import '../../domain/candidate.dart';
import '../../domain/cluster_proposal.dart';
import '../../domain/home_region.dart';
import '../../domain/json_utils.dart' show Coord;
import '../../domain/trip_bbox.dart';
import '../../state/providers.dart';
import '../../state/settings_provider.dart';
import 'anchor_area_layer.dart';
import 'candidate_geometry_layer.dart';
import 'map_attribution.dart';
import 'map_label_scale.dart';
import 'no_basemap_notice.dart';
import 'tap_to_pick_map.dart' show MapAnchorPoint, MapMarkerPoint, MapTileAssets;
import 'vector_tile_provider.dart';

CandidateRoleAffinity _markerAffinity(RoleAffinity affinity) => switch (affinity) {
      RoleAffinity.narrative => CandidateRoleAffinity.narrative,
      RoleAffinity.provision => CandidateRoleAffinity.provision,
      RoleAffinity.station => CandidateRoleAffinity.station,
    };

class CandidateMap extends ConsumerStatefulWidget {
  const CandidateMap({
    super.key,
    required this.candidates,
    this.bbox,
    this.onCandidateTap,
    this.initialZoom = 13,
    this.initialCameraFit,
    this.proposals = const [],
    this.selectedProposalId,
    this.onProposalTap,
    this.route = const [],
    this.onMapTap,
    this.pickedCoord,
    this.anchors = const [],
    this.nodes = const [],
  });

  final List<Candidate> candidates;

  /// Drawn as a backdrop outline, same convention as `TapToPickMap.outline`.
  final TripBbox? bbox;
  final void Function(Candidate)? onCandidateTap;
  final double initialZoom;

  /// Issue #325 — an explicit initial camera fit (e.g. the offline buffer
  /// around a finished route), overriding [initialZoom]/[bbox]'s centering
  /// for callers that need a real "fit to this extent" rather than a fixed
  /// zoom. `null` (every caller before #325) preserves the original
  /// center/zoom behaviour exactly.
  final CameraFit? initialCameraFit;

  /// N4a — cluster proposals drawn as extent circles + a centroid marker,
  /// synchronized with the proposal list: [selectedProposalId] is emphasized,
  /// and a tap on a proposal calls [onProposalTap] (which selects its card).
  final List<ClusterProposal> proposals;
  final String? selectedProposalId;
  final void Function(ClusterProposal)? onProposalTap;

  /// Optional lon/lat polyline(s) of the current route, drawn so an Author
  /// can see which proposals sit off the corridor. One entry per separate
  /// line (issue #325's rest-day picker draws every segment across the
  /// whole trip, which are not necessarily one continuous path) — a caller
  /// with a single continuous route passes a one-element list.
  final List<List<Coord>> route;

  /// Issue #325 — a tap on the map background rather than a marker, for the
  /// rest-day location picker's hand-placement fallback ("every stage after
  /// display is skippable" — an Author who knows the spot is not forced
  /// through the candidate/search list). `null` (every caller before #325)
  /// means the map background is not tappable, exactly as before.
  final void Function(Coord)? onMapTap;

  /// Issue #325 — draws one distinct pin for a caller's current pick (from
  /// a candidate tap, a search result, or [onMapTap]'s hand-placement),
  /// separate from the salience-scaled [CandidateMarker]s so it reads as
  /// "this is what you chose" rather than another candidate.
  final Coord? pickedCoord;

  /// #410 — the trip's promoted anchors (`anchor_map_points.dart`), drawn
  /// above the candidate layer as [AnchorMarker]s. A candidate whose id is
  /// an anchor's `sourceId` is *not* drawn as a candidate any more: the
  /// anchor mark stands where its pin stood, so promotion visibly changes
  /// the map instead of leaving the cache's mark untouched under canon —
  /// and a tap there no longer offers a promotion that would only throw
  /// `DuplicatePromotionException`.
  final List<MapAnchorPoint> anchors;

  /// #410 — the trip's authored nodes, drawn as the same [NodeMarker]s the
  /// Route tab draws them with (lodging and other day-scoped POIs, e.g.
  /// `logistics_tab.dart`'s `promoteCandidate` path). The Layers tab's own
  /// direct tap-to-promote wrote a day-scoped `Node` the same way before
  /// #477 moved it onto `promoteAnchor`; a candidate at exactly a node's
  /// coordinate is still retired here for whatever other path still
  /// produces one.
  final List<MapMarkerPoint> nodes;

  @override
  ConsumerState<CandidateMap> createState() => _CandidateMapState();
}

/// The candidates still drawn as candidates once [anchors] and [nodes] have
/// claimed theirs — by source id for an anchor, by exact coordinate for a
/// node. Pure, so the retirement rule is testable without a map.
@visibleForTesting
List<Candidate> unpromotedCandidates(
  List<Candidate> candidates,
  List<MapAnchorPoint> anchors,
  List<MapMarkerPoint> nodes,
) {
  if (anchors.isEmpty && nodes.isEmpty) return candidates;
  final promotedIds = {for (final a in anchors) if (a.sourceId != null) a.sourceId!};
  bool atNode(Coord c) =>
      nodes.any((n) => n.coord[0] == c[0] && n.coord[1] == c[1]);
  return [
    for (final c in candidates)
      if (!promotedIds.contains(c.id) && !atNode(c.coord)) c,
  ];
}

class _CandidateMapState extends ConsumerState<CandidateMap> {
  final _mapController = MapController();
  bool _mapReady = false;

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final isDark = material.Theme.of(context).brightness == Brightness.dark;
    final basemapStyle = ref.watch(settingsProvider).basemapStyle;
    final labelScale = resolveMapLabelScale(
      MediaQuery.textScalerOf(context).scale(1),
      MediaQuery.devicePixelRatioOf(context),
    );
    final center = widget.bbox?.center ??
        (widget.candidates.isNotEmpty ? widget.candidates.first.coord : HomeRegion.center);
    final sidecar = ref.watch(sidecarManagerProvider);
    final baseUrl = sidecar.baseUrl;
    final tilesArchiveId = sidecar.capabilities?.tilesArchiveId;
    // #410 — promoted candidates are drawn by their anchor/node, not twice.
    final candidates = unpromotedCandidates(widget.candidates, widget.anchors, widget.nodes);

    return FutureBuilder(
      future: MapTileAssets.theme(resolveBasemapStyleName(isDark, basemapStyle),
          labelScale: labelScale),
      builder: (context, snapshot) {
        final themeResult = snapshot.data;
        final vectorTheme = themeResult?.theme;
        final provider = SidecarVectorTileProvider(baseUrl);
        final tilesAvailable = vectorTheme != null;
        // issue #184: a settled result that is not `ok` is a
        // basemap-style defect, distinct from a legitimate
        // out-of-coverage viewport.
        final styleFailed = themeResult != null && !themeResult.ok;
        final outOfCoverage = _mapReady &&
            !tilesLikelyCoverViewport(_mapController.camera.visibleBounds, tripBbox: widget.bbox);

        return Stack(children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: ll.LatLng(center[1], center[0]),
              initialZoom: widget.initialZoom,
              initialCameraFit: widget.initialCameraFit,
              onMapEvent: (_) => setState(() {}),
              onMapReady: () => setState(() => _mapReady = true),
              onTap: widget.onMapTap == null
                  ? null
                  : (_, point) => widget.onMapTap!([point.longitude, point.latitude]),
            ),
            children: [
              // Issue #230 C1 — ground under the tiles, not a fallback.
              MapGraticule(ground: c.surfaceSunk, line: c.textMuted, label: c.textSecondary),
              if (tilesAvailable)
                VectorTileLayer(
                  theme: vectorTheme,
                  tileProviders: TileProviders({'protomaps': provider}),
                  maximumZoom: basemapMaximumZoom.toDouble(),
                  cacheFolder: basemapCacheFolderCallback(tilesArchiveId),
                ),
              if (widget.bbox != null)
                PolygonLayer(polygons: [
                  Polygon(
                    points: [for (final p in widget.bbox!.outline) ll.LatLng(p[1], p[0])],
                    color: c.primary.withValues(alpha: 0.05),
                    borderColor: c.primary,
                    borderStrokeWidth: 2,
                  ),
                ]),
              if (widget.route.any((line) => line.length >= 2))
                PolylineLayer(polylines: [
                  for (final line in widget.route)
                    if (line.length >= 2)
                      Polyline(
                        points: [for (final p in line) ll.LatLng(p[1], p[0])],
                        color: c.info,
                        strokeWidth: 3,
                      ),
                ]),
              if (widget.proposals.isNotEmpty)
                CircleLayer(circles: [
                  for (final p in widget.proposals)
                    CircleMarker(
                      point: ll.LatLng(p.centroid[1], p.centroid[0]),
                      radius: p.extentM.clamp(30, 400).toDouble(),
                      useRadiusInMeter: true,
                      color: c.primary.withValues(
                          alpha: p.id == widget.selectedProposalId ? 0.22 : 0.08),
                      borderColor: c.primary,
                      borderStrokeWidth: p.id == widget.selectedProposalId ? 2.5 : 1,
                    ),
                ]),
              if (widget.proposals.isNotEmpty)
                MarkerLayer(markers: [
                  for (final p in widget.proposals)
                    Marker(
                      point: ll.LatLng(p.centroid[1], p.centroid[0]),
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onProposalTap == null
                            ? null
                            : () => widget.onProposalTap!(p),
                        child: Tooltip(
                          message: '${p.name} — ${p.members.length} features',
                          child: Icon(
                            p.id == widget.selectedProposalId
                                ? Icons.trip_origin
                                : Icons.adjust,
                            color: c.primary,
                            size: p.id == widget.selectedProposalId ? 26 : 20,
                          ),
                        ),
                      ),
                    ),
                ]),
              // Issue #475 — a polygon/line candidate's own extent, under
              // its marker (the pin stays the guaranteed tap target). Fed
              // the retired list (#484): a promoted candidate's ring is drawn
              // from the anchor below, and a tap on it must not offer the
              // promotion #410 already withdrew from its pin.
              if (candidates.any((candidate) => candidate.geometry != null))
                CandidateGeometryLayer(
                  candidates: candidates,
                  onCandidateTap: widget.onCandidateTap,
                ),
              // #484 — area anchors' boundaries. A promoted area candidate is
              // retired from the candidate layer above, so the ring it had
              // there is drawn here from the anchor's own copy instead of
              // vanishing at promotion. Under every marker: a pin inside a
              // district stays a pin, not a tinted one.
              if (widget.anchors.any((a) => a.rings != null))
                AnchorAreaLayer(anchors: widget.anchors),
              MarkerLayer(markers: [
                for (final candidate in candidates)
                  Marker(
                    point: ll.LatLng(candidate.coord[1], candidate.coord[0]),
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onCandidateTap == null
                          ? null
                          : () => widget.onCandidateTap!(candidate),
                      child: Tooltip(
                        message: candidate.title ??
                            '${candidate.layer} (${(candidate.salience * 100).round()}% salience)',
                        child: CandidateMarker(
                          salience: candidate.salience,
                          roleAffinity: _markerAffinity(candidate.roleAffinity),
                        ),
                      ),
                    ),
                  ),
              ]),
              // #410 — canon above cache: the trip's nodes, then its anchors,
              // drawn over the candidate layer so a promoted place reads as
              // promoted wherever it sits among the candidates.
              if (widget.nodes.isNotEmpty)
                MarkerLayer(markers: [
                  for (final n in widget.nodes)
                    Marker(
                      point: ll.LatLng(n.coord[1], n.coord[0]),
                      width: 28,
                      height: 28,
                      child: NodeMarker(n.role),
                    ),
                ]),
              if (widget.anchors.isNotEmpty)
                MarkerLayer(markers: [
                  for (final a in widget.anchors)
                    Marker(
                      point: ll.LatLng(a.coord[1], a.coord[0]),
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      child: Tooltip(
                        message: a.label,
                        child: AnchorMarker(mark: a.mark),
                      ),
                    ),
                ]),
              if (widget.pickedCoord != null)
                MarkerLayer(markers: [
                  Marker(
                    point: ll.LatLng(widget.pickedCoord![1], widget.pickedCoord![0]),
                    width: 36,
                    height: 36,
                    alignment: Alignment.topCenter,
                    child: IgnorePointer(
                      child: Icon(Icons.location_pin, color: c.primary, size: 36),
                    ),
                  ),
                ]),
            ],
          ),
          if (!tilesAvailable || outOfCoverage)
            Positioned(
              left: PlotSpacing.s3,
              bottom: PlotSpacing.s3 + 26,
              child: NoBasemapNotice(
                loading: snapshot.connectionState != ConnectionState.done,
                outOfCoverage: tilesAvailable && outOfCoverage,
                styleFailed: styleFailed,
              ),
            ),
          // K10/FR95 (issue #230 C1) — every map surface carries the credit.
          const Positioned(
            left: PlotSpacing.s3,
            bottom: PlotSpacing.s3,
            child: MapAttribution(),
          ),
        ]);
      },
    );
  }
}
