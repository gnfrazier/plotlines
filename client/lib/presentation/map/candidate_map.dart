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
import 'package:latlong2/latlong.dart' as ll;
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../../domain/candidate.dart';
import '../../domain/trip_bbox.dart';
import 'tap_to_pick_map.dart' show MapTileAssets, MapGraticule;
import 'vector_tile_provider.dart';

CandidateRoleAffinity _markerAffinity(RoleAffinity affinity) => switch (affinity) {
      RoleAffinity.narrative => CandidateRoleAffinity.narrative,
      RoleAffinity.provision => CandidateRoleAffinity.provision,
      RoleAffinity.station => CandidateRoleAffinity.station,
    };

class CandidateMap extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final isDark = material.Theme.of(context).brightness == Brightness.dark;
    final center = bbox?.center ??
        (candidates.isNotEmpty ? candidates.first.coord : const [-105.2705, 40.0150]);

    return FutureBuilder(
      future: Future.wait([MapTileAssets.theme(isDark ? 'dark' : 'light'), MapTileAssets.provider()]),
      builder: (context, snapshot) {
        final results = snapshot.data;
        final vectorTheme = results?[0] as Theme?;
        final provider = results?[1] as DirectoryVectorTileProvider?;
        final tilesAvailable = vectorTheme != null && provider != null;

        return FlutterMap(
          options: MapOptions(
            initialCenter: ll.LatLng(center[1], center[0]),
            initialZoom: initialZoom,
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
            if (bbox != null)
              PolygonLayer(polygons: [
                Polygon(
                  points: [for (final p in bbox!.outline) ll.LatLng(p[1], p[0])],
                  color: c.primary.withValues(alpha: 0.05),
                  borderColor: c.primary,
                  borderStrokeWidth: 2,
                ),
              ]),
            MarkerLayer(markers: [
              for (final candidate in candidates)
                Marker(
                  point: ll.LatLng(candidate.coord[1], candidate.coord[0]),
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onCandidateTap == null ? null : () => onCandidateTap!(candidate),
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
        );
      },
    );
  }
}
