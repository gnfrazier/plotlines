// Issue #572 — the one place a map with no trip bbox turns the trip's own
// geometry into a camera. See `domain/trip_extent.dart` for why, and for why
// this never becomes the bbox itself.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../domain/domain.dart';
import '../../domain/trip_extent.dart';

/// A camera fit over everything [trip] has placed, or null when it has placed
/// nothing (the caller's `HomeRegion` fallback stands). Capped at z14 so a
/// trip with a single placed point frames its surroundings, not one block.
CameraFit? tripFramingFit(Trip trip) {
  final e = tripExtentOf(trip);
  if (e == null) return null;
  return CameraFit.bounds(
    bounds: LatLngBounds(ll.LatLng(e.minLat, e.minLon), ll.LatLng(e.maxLat, e.maxLon)),
    padding: const EdgeInsets.all(48),
    maxZoom: 14,
  );
}
