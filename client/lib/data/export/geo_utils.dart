// Shared geometry helpers for the export writers — extracted from
// tcx_writer.dart's original private haversine so gpx/geojson can place a
// cue (which only carries `distanceAlongM`, not a coordinate — see
// domain/cue.dart) on the line too, not just TCX.
library;

import 'dart:math' as math;

import '../../domain/domain.dart';

const _earthRm = 6371000.0;

double haversineM(Coord a, Coord b) {
  final lat1 = a[1] * math.pi / 180.0;
  final lat2 = b[1] * math.pi / 180.0;
  final dLat = (b[1] - a[1]) * math.pi / 180.0;
  final dLon = (b[0] - a[0]) * math.pi / 180.0;
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * _earthRm * math.asin(math.min(1.0, math.sqrt(h)));
}

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
