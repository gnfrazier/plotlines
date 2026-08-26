// Shared geometry helpers for the export writers — extracted from
// tcx_writer.dart's original private haversine so gpx/geojson can place a
// cue (which only carries `distanceAlongM`, not a coordinate — see
// domain/cue.dart) on the line too, not just TCX.
//
// `haversineM` itself moved to `domain/passage_sequence.dart` when B2/FR11
// needed the same measurement for a transition's adjacency gap: great-circle
// distance is a fact about two coordinates, not an export concern, and two
// copies of it is one copy too many to keep agreeing with
// `trips/compose.py`'s. Callers get it from the domain barrel, which every
// writer here already imports.
library;

import '../../domain/domain.dart';

/// The point [targetM] along [coords], linearly interpolated between the
/// two vertices it falls between. Clamps to the first/last vertex outside
/// the line's range rather than extrapolating.
Coord pointAtDistance(List<Coord> coords, double targetM) {
  if (coords.isEmpty) return const [0, 0];
  if (coords.length == 1 || targetM <= 0) return coords.first;
  var cumulative = 0.0;
  for (var i = 1; i < coords.length; i++) {
    final segLen = haversineM(coords[i - 1], coords[i]);
    if (cumulative + segLen >= targetM) {
      final frac = segLen <= 0 ? 0.0 : ((targetM - cumulative) / segLen).clamp(0.0, 1.0);
      final lon = coords[i - 1][0] + (coords[i][0] - coords[i - 1][0]) * frac;
      final lat = coords[i - 1][1] + (coords[i][1] - coords[i - 1][1]) * frac;
      return [lon, lat];
    }
    cumulative += segLen;
  }
  return coords.last;
}
