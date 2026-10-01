// Issue #572 — where a trip *is* when it has no drawn bbox.
//
// A trip can be open with no bbox — never drawn yet, or saved before #570
// persisted it — and the maps that frame on it used to fall back to `HomeRegion` — a
// Greensboro trip opened its Proposals map over Asheville. The trip's own
// geometry is a better answer than any fixed place: every passage's route
// and placed points, each day's location and nodes, and every anchor.
//
// This only frames a camera. It never becomes the trip bbox — FR120's one
// extent is drawn by the Author, never inferred (N1's AC: "the location
// never becomes the bbox by inference or radius").
library;

import 'domain.dart';
import 'trip_bbox.dart';

/// The bounds of everything [trip] has placed, or null when it has placed
/// nothing yet (a fresh trip, where `HomeRegion` remains the fallback).
/// A single placed point gives a zero-area box; callers cap the zoom.
TripBbox? tripExtentOf(Trip trip) {
  double? minLat, minLon, maxLat, maxLon;
  void add(Coord? c) {
    if (c == null || c.length < 2) return;
    final lon = c[0], lat = c[1];
    minLat = minLat == null ? lat : (lat < minLat! ? lat : minLat);
    maxLat = maxLat == null ? lat : (lat > maxLat! ? lat : maxLat);
    minLon = minLon == null ? lon : (lon < minLon! ? lon : minLon);
    maxLon = maxLon == null ? lon : (lon > maxLon! ? lon : maxLon);
  }

  for (final day in trip.days) {
    add(day.location);
    for (final n in day.nodes) {
      add(n.coord);
    }
    for (final s in day.segments) {
      add(s.start);
      add(s.end);
      s.via.forEach(add);
      s.geometry?.coordinates.forEach(add);
      for (final n in s.nodes) {
        add(n.coord);
      }
    }
  }
  for (final a in trip.anchors) {
    add(a.coord);
  }
  if (minLat == null) return null;
  return TripBbox(minLat: minLat!, minLon: minLon!, maxLat: maxLat!, maxLon: maxLon!);
}
