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
import '../../domain/trip_bbox.dart';
import '../../state/providers.dart';
import 'no_basemap_notice.dart';
import 'tap_to_pick_map.dart' show MapTileAssets;
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
    this.proposals = const [],
    this.selectedProposalId,
    this.onProposalTap,
    this.route = const [],
  });

  final List<Candidate> candidates;

  /// Drawn as a backdrop outline, same convention as `TapToPickMap.outline`.
  final TripBbox? bbox;
  final void Function(Candidate)? onCandidateTap;
  final double initialZoom;

  /// N4a — cluster proposals drawn as extent circles + a centroid marker,
  /// synchronized with the proposal list: [selectedProposalId] is emphasized,
  /// and a tap on a proposal calls [onProposalTap] (which selects its card).
  final List<ClusterProposal> proposals;
  final String? selectedProposalId;
  final void Function(ClusterProposal)? onProposalTap;

  /// Optional lon/lat polyline of the current route, drawn so an Author can
  /// see which proposals sit off the corridor.
  final List<List<double>> route;

  @override
  ConsumerState<CandidateMap> createState() => _CandidateMapState();
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
    final center = widget.bbox?.center ??
        (widget.candidates.isNotEmpty ? widget.candidates.first.coord : HomeRegion.center);
    final baseUrl = ref.watch(sidecarManagerProvider).baseUrl;

    return FutureBuilder(
      future: MapTileAssets.theme(isDark ? 'dark' : 'light'),
      builder: (context, snapshot) {
        final vectorTheme = snapshot.data;
        final provider = SidecarVectorTileProvider(baseUrl);
        final tilesAvailable = vectorTheme != null;
        final outOfCoverage = _mapReady &&
            !tilesLikelyCoverViewport(_mapController.camera.visibleBounds, tripBbox: widget.bbox);

        return Stack(children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: ll.LatLng(center[1], center[0]),
              initialZoom: widget.initialZoom,
              onMapEvent: (_) => setState(() {}),
              onMapReady: () => setState(() => _mapReady = true),
            ),
            children: [
              if (tilesAvailable)
                VectorTileLayer(
                  theme: vectorTheme,
                  tileProviders: TileProviders({'protomaps': provider}),
                  maximumZoom: 15,
                )
              else
                MapGraticule(color: c.border),
              if (widget.bbox != null)
                PolygonLayer(polygons: [
                  Polygon(
                    points: [for (final p in widget.bbox!.outline) ll.LatLng(p[1], p[0])],
                    color: c.primary.withValues(alpha: 0.05),
                    borderColor: c.primary,
                    borderStrokeWidth: 2,
                  ),
                ]),
              if (widget.route.length >= 2)
                PolylineLayer(polylines: [
                  Polyline(
                    points: [for (final p in widget.route) ll.LatLng(p[1], p[0])],
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
              MarkerLayer(markers: [
                for (final candidate in widget.candidates)
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
            ],
          ),
          if (!tilesAvailable || outOfCoverage)
            Positioned(
              left: PlotSpacing.s3,
              bottom: PlotSpacing.s3,
              child: NoBasemapNotice(
                loading: snapshot.connectionState != ConnectionState.done,
                outOfCoverage: tilesAvailable && outOfCoverage,
              ),
            ),
        ]);
      },
    );
  }
}
