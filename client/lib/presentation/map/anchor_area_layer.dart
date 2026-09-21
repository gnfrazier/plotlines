// Issue #484 (FR108 / O3) — an area anchor's own boundary on the planning
// maps. #410 put every anchor on the map at its representative point and
// deferred the ring to #475, but #475 outlines `Candidate.geometry` — the
// pre-promotion cache object — and `CandidateMap` retires a candidate the
// moment it is promoted. So an area candidate had a ring right up until the
// Author promoted it, and then it was a dot. This layer draws the ring the
// anchor carries (`Anchor.area`, drawn or adopted at promotion) on both
// `TapToPickMap` and `CandidateMap`, so the boundary is what promotion
// *keeps*, not what it loses.
//
// Styling: an anchor is canon, so its ring has one fixed weight rather than
// a candidate's salience ramp, and it sits on a paper casing the way a route
// does — the casing, not the colour, is what tells a promoted boundary from
// a candidate's bare Blaze ring at the same place (brand rule: shape and
// treatment carry meaning, colour only reinforces). Holes are drawn with
// their own border so an excluded block inside a district reads as excluded.
//
// Gating: a trip has as many area anchors as the Author promoted — tens, not
// SPIKE-G's thousands — so there is no cap. The screen-extent gate is kept
// (a ring that would not clear the marker it sits under adds nothing) and
// the viewport cull with it, both pure functions of the camera
// (`planAnchorOutlines`).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:plotlines_ui/plotlines_ui.dart';

import 'tap_to_pick_map.dart' show LatLonPoint, MapAnchorPoint;

/// One anchor boundary the planner decided to draw, with the screen extent
/// it was judged on (the longer side of its screen-space bbox, px).
class AnchorOutline {
  const AnchorOutline({required this.anchor, required this.screenExtentPx});

  final MapAnchorPoint anchor;
  final double screenExtentPx;

  List<LatLonPoint> get exterior => anchor.rings!.first;
  List<List<LatLonPoint>> get holes => anchor.rings!.skip(1).toList();
}

/// A closed ring needs at least four positions (three vertices plus the
/// repeated first); anything shorter is skipped rather than thrown on.
bool _drawable(List<List<LatLonPoint>>? rings) =>
    rings != null && rings.isNotEmpty && rings.first.length >= 4;

LatLngBounds _boundsOf(List<LatLonPoint> ring) =>
    LatLngBounds.fromPoints([for (final p in ring) ll.LatLng(p[1], p[0])]);

/// Decide which anchors' boundaries to draw for the current camera.
///
/// [project] is the camera's lon/lat → screen-offset projection
/// (`MapCamera.latLngToScreenOffset`); [visible] its visible bounds, or
/// `null` to skip the viewport cull (tests). The result is ordered largest
/// extent first so a smaller area inside a larger one paints on top.
List<AnchorOutline> planAnchorOutlines(
  List<MapAnchorPoint> anchors, {
  required Offset Function(ll.LatLng) project,
  LatLngBounds? visible,
  double minScreenExtentPx = AnchorAreaLayer.defaultMinScreenExtentPx,
}) {
  final passing = <AnchorOutline>[];
  for (final anchor in anchors) {
    if (!_drawable(anchor.rings)) continue;
    final bounds = _boundsOf(anchor.rings!.first);
    if (visible != null && !visible.isOverlapping(bounds)) continue;
    final a = project(bounds.northWest);
    final b = project(bounds.southEast);
    final extent = math.max((a.dx - b.dx).abs(), (a.dy - b.dy).abs());
    if (extent < minScreenExtentPx) continue;
    passing.add(AnchorOutline(anchor: anchor, screenExtentPx: extent));
  }
  return passing..sort((x, y) => y.screenExtentPx.compareTo(x.screenExtentPx));
}

/// A `FlutterMap` child: the boundary of every anchor in [anchors] that
/// carries one and passes the gates above for the current camera.
class AnchorAreaLayer extends StatelessWidget {
  const AnchorAreaLayer({
    super.key,
    required this.anchors,
    this.minScreenExtentPx = defaultMinScreenExtentPx,
  });

  /// Matches `CandidateGeometryLayer`'s gate: 1.5× the marker slot.
  static const defaultMinScreenExtentPx = 48.0;

  /// Fixed, promoted-tier weights. The stroke sits between a candidate
  /// ring's floor (1.4) and ceiling (3.0) but at full opacity; the casing
  /// adds 1.5 px of paper either side; the fill is a wash, never opaque.
  static const strokeWidth = 2.5;
  static const casingWidth = strokeWidth + 3.0;
  static const fillOpacity = 0.10;

  final List<MapAnchorPoint> anchors;
  final double minScreenExtentPx;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final c = PlotColors.of(context);
    final plan = planAnchorOutlines(
      anchors,
      project: camera.latLngToScreenOffset,
      visible: camera.visibleBounds,
      minScreenExtentPx: minScreenExtentPx,
    );
    if (plan.isEmpty) return const SizedBox.shrink();

    List<ll.LatLng> toLatLng(List<LatLonPoint> ring) =>
        [for (final p in ring) ll.LatLng(p[1], p[0])];

    // Every casing first, then every stroke, so where two anchors touch
    // neither casing cuts across the other's stroke.
    return PolygonLayer(polygons: [
      for (final o in plan)
        Polygon(
          points: toLatLng(o.exterior),
          holePointsList: [for (final h in o.holes) toLatLng(h)],
          borderColor: c.surfaceCard,
          borderStrokeWidth: casingWidth,
        ),
      for (final o in plan)
        Polygon(
          points: toLatLng(o.exterior),
          holePointsList: [for (final h in o.holes) toLatLng(h)],
          color: c.primary.withValues(alpha: fillOpacity),
          borderColor: c.primary,
          borderStrokeWidth: strokeWidth,
        ),
    ]);
  }
}
