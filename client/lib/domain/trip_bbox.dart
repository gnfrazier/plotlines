// N1 (PRD FR120) — the trip's authoring bbox, drawn by the Author at trip
// initiation and revisable throughout authoring. **Not yet part of
// `trip_payload.schema.json`**: the v2.0 schema growth that adds a bbox
// field is called out in `docs/Plotlines_ARCHITECTURE_v2.md` (§11.6, D41)
// as "a schema version bump with a migration, not an additive edit" bundled
// with anchors/roles/polygons/arc-on-passages — none of which exist in this
// codebase yet. This type is deliberately outside `domain/domain.dart`'s
// schema-backed barrel for that reason; see `state/trip_bbox_provider.dart`
// for how it's held for now.
//
// Distinct from `HomeRegion` (A10's shipped constant) and from the offline
// corridor buffer (C14, Character-side) — this is the one extent that
// scopes an Author's trip.
library;

import 'dart:math' as math;

/// [lon, lat] pair, matching `HomeRegion`/`TapToPickMap`'s convention.
typedef LatLon = List<double>;

/// An axis-aligned bounding box in WGS84 degrees.
class TripBbox {
  const TripBbox({
    required this.minLat,
    required this.minLon,
    required this.maxLat,
    required this.maxLon,
  })  : assert(minLat <= maxLat),
        assert(minLon <= maxLon);

  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;

  /// Builds a box from two arbitrary corners — order doesn't matter, this
  /// normalizes to min/max the way a drag-to-draw gesture hands back
  /// whichever corner the Author started from.
  factory TripBbox.fromCorners(LatLon a, LatLon b) => TripBbox(
        minLat: math.min(a[1], b[1]),
        maxLat: math.max(a[1], b[1]),
        minLon: math.min(a[0], b[0]),
        maxLon: math.max(a[0], b[0]),
      );

  bool contains(LatLon point) =>
      point[1] >= minLat && point[1] <= maxLat && point[0] >= minLon && point[0] <= maxLon;

  double get centerLat => (minLat + maxLat) / 2;
  double get centerLon => (minLon + maxLon) / 2;
  LatLon get center => [centerLon, centerLat];

  /// `[west, south, east, north]` — the sidecar's `POST /regions` bbox order
  /// (issue #154; matches `plotlines_core.graph.regions`' osmnx convention).
  List<double> get bboxWsen => [minLon, minLat, maxLon, maxLat];

  /// Corners in the same winding order as `HomeRegion.outline`, for reuse
  /// with `TapToPickMap`'s `outline` param.
  List<LatLon> get outline => [
        [minLon, minLat],
        [maxLon, minLat],
        [maxLon, maxLat],
        [minLon, maxLat],
      ];

  /// Great-circle width along the box's center latitude, in kilometers —
  /// the FR120 extent readout's basis (converted to the Author's display
  /// unit by the caller).
  double get widthKm => _haversineKm(centerLat, minLon, centerLat, maxLon);

  /// Great-circle height along the box's center meridian, in kilometers.
  double get heightKm => _haversineKm(minLat, centerLon, maxLat, centerLon);

  /// The smallest bbox containing this one plus every one of [points] —
  /// the shrink prompt's "move the bounds to include all three" (Flow 9).
  TripBbox expandToInclude(Iterable<LatLon> points) {
    var lo = minLat, hi = maxLat, lf = minLon, rt = maxLon;
    for (final p in points) {
      lo = math.min(lo, p[1]);
      hi = math.max(hi, p[1]);
      lf = math.min(lf, p[0]);
      rt = math.max(rt, p[0]);
    }
    return TripBbox(minLat: lo, maxLat: hi, minLon: lf, maxLon: rt);
  }

  /// Returns this box with one or more edges moved — the basis for
  /// corner-handle resize, where a dragged corner controls exactly one lat
  /// edge and one lon edge (e.g. the NW handle controls `maxLat`/`minLon`).
  /// Normalizes afterward so a drag that crosses the opposite edge flips
  /// the box rather than producing an inverted (min > max) one.
  TripBbox copyWith({double? minLat, double? minLon, double? maxLat, double? maxLon}) {
    final a = [minLon ?? this.minLon, minLat ?? this.minLat];
    final b = [maxLon ?? this.maxLon, maxLat ?? this.maxLat];
    return TripBbox.fromCorners(a, b);
  }

  @override
  bool operator ==(Object other) =>
      other is TripBbox &&
      other.minLat == minLat &&
      other.minLon == minLon &&
      other.maxLat == maxLat &&
      other.maxLon == maxLon;

  @override
  int get hashCode => Object.hash(minLat, minLon, maxLat, maxLon);

  @override
  String toString() =>
      'TripBbox(minLat: $minLat, minLon: $minLon, maxLat: $maxLat, maxLon: $maxLon)';
}

double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusKm = 6371.0;
  final dLat = _deg2rad(lat2 - lat1);
  final dLon = _deg2rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_deg2rad(lat1)) * math.cos(_deg2rad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadiusKm * c;
}

double _deg2rad(double deg) => deg * math.pi / 180;
