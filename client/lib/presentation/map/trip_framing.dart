// Issue #572 — the one place a map with no trip bbox turns the trip's own
// geometry into a camera. See `domain/trip_extent.dart` for why, and for why
// this never becomes the bbox itself.
//
// Issues #612/#614/#618/#619 — and the one place any map with no caller-given
// camera finds the open trip's area. `TapToPickMap` and `CandidateMap` used to
// fall straight from "no center passed" to `HomeRegion`, so every dialog and
// screen that opened a map without a center (New Route, the route day's own
// map on a blank day, the lodging picker) opened over Buncombe County whatever
// the trip area was. They now ask [tripAreaFit] first.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../domain/domain.dart';
import '../../domain/trip_bbox.dart';
import '../../domain/trip_extent.dart';

/// A camera fit over everything [trip] has placed, or null when it has placed
/// nothing (the caller's `HomeRegion` fallback stands). Capped at z14 so a
/// trip with a single placed point frames its surroundings, not one block.
CameraFit? tripFramingFit(Trip trip) {
  final e = tripExtentOf(trip);
  if (e == null) return null;
  return _fit(e, padding: 48);
}

/// The open trip's area as a camera: the drawn [bbox] when there is one,
/// else everything [trip] has placed ([tripFramingFit]), else null — the one
/// case `HomeRegion` is still the right backdrop (no trip area exists yet).
CameraFit? tripAreaFit(TripBbox? bbox, Trip trip) =>
    bbox != null ? _fit(bbox, padding: 24) : tripFramingFit(trip);

CameraFit _fit(TripBbox b, {required double padding}) => CameraFit.bounds(
      bounds: LatLngBounds(ll.LatLng(b.minLat, b.minLon), ll.LatLng(b.maxLat, b.maxLon)),
      padding: EdgeInsets.all(padding),
      maxZoom: 14,
    );
