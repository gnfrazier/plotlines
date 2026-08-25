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
  });

  final List<Candidate> candidates;

  /// Drawn as a backdrop outline, same convention as `TapToPickMap.outline`.
  final TripBbox? bbox;
  final void Function(Candidate)? onCandidateTap;
  final double initialZoom;

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
