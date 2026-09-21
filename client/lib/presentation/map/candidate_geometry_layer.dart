// Issue #475 (FR99 / FR100, K12 / FR142(b)) — a polygon or line candidate's
// own geometry on `CandidateMap`. #403 carried `Candidate.geometry` from the
// provider to the client; until this layer nothing drew it, so a 40 km byway
// and a 250,000 m² reserve were both still a pin. The pin stays (it is the
// tap target every consumer can rely on, `Candidate.coord`); this layer adds
// the extent *around* it, styled with the same salience vocabulary as
// `CandidateMarker` — Blaze, ring weight and fill opacity scaled by salience,
// never colour alone — and tap-selectable through the same `onCandidateTap`.
//
// Density: SPIKE-G's model prices polygon vertices at ~1–2 ms/frame for
// ~100 area candidates on a GPU desktop, and calls the filled polygons the
// dominant cost on the software-raster floor. Two gates keep the outline
// count bounded, both pure functions of the camera (`planCandidateOutlines`):
//
//  1. **Screen extent** — an outline is drawn only when it would span at
//     least [CandidateGeometryLayer.minScreenExtentPx] on screen. Below that
//     the pin already says everything the ring could, so at the trip-overview
//     zoom only the features whose extent actually reads (a byway, a
//     wilderness boundary) get an outline, and zooming in reveals the rest
//     as they grow past the pin.
//  2. **Salience cap** — of those, at most [CandidateGeometryLayer.maxOutlines]
//     draw, highest salience first. 300 mirrors SPIKE-G's derived K for
//     widget markers; the count beyond it is the marker's job, not the ring's.
//
// Both are viewport-relative: a candidate whose geometry does not overlap the
// visible bounds is not considered at all.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/candidate.dart';
import '../../domain/json_utils.dart' show Coord;

/// One candidate outline the planner decided to draw, with the screen
/// extent it was judged on (the longer side of its screen-space bbox, px).
class CandidateOutline {
  const CandidateOutline({required this.candidate, required this.screenExtentPx});

  final Candidate candidate;
  final double screenExtentPx;

  CandidateGeometry get geometry => candidate.geometry!;
}

/// The lon/lat vertices of a candidate's geometry, or `null` for a point
/// candidate (or a degenerate ring/path nothing could be drawn from).
List<Coord>? _vertices(Candidate candidate) => switch (candidate.geometry) {
      CandidatePolygon(ring: final ring) => ring.length >= 4 ? ring : null,
      CandidateLine(coords: final coords) => coords.length >= 2 ? coords : null,
      null => null,
    };

LatLngBounds _boundsOf(List<Coord> vertices) =>
    LatLngBounds.fromPoints([for (final p in vertices) ll.LatLng(p[1], p[0])]);

/// Decide which candidates' geometry to outline for the current camera.
///
/// [project] is the camera's lon/lat → screen-offset projection
/// (`MapCamera.latLngToScreenOffset`); [visible] its visible bounds, or
/// `null` to skip the viewport cull (tests). The result is ordered
/// **largest extent first**, so drawing it in order paints the smallest
/// feature last and on top, and a tap that lands inside several nested
/// polygons (a park in a district) resolves to the innermost by taking the
/// last hit.
List<CandidateOutline> planCandidateOutlines(
  List<Candidate> candidates, {
  required Offset Function(ll.LatLng) project,
  LatLngBounds? visible,
  double minScreenExtentPx = CandidateGeometryLayer.defaultMinScreenExtentPx,
  int maxOutlines = CandidateGeometryLayer.defaultMaxOutlines,
}) {
  final passing = <CandidateOutline>[];
  for (final candidate in candidates) {
    final vertices = _vertices(candidate);
    if (vertices == null) continue;
    final bounds = _boundsOf(vertices);
    if (visible != null && !visible.isOverlapping(bounds)) continue;
    // The screen bbox of the geometry's lon/lat bbox: two projections per
    // candidate, whatever the vertex count. Under rotation this is the
    // extent of the unrotated bbox, which is close enough for a gate.
    final a = project(bounds.northWest);
    final b = project(bounds.southEast);
    final extent = math.max((a.dx - b.dx).abs(), (a.dy - b.dy).abs());
    if (extent < minScreenExtentPx) continue;
    passing.add(CandidateOutline(candidate: candidate, screenExtentPx: extent));
  }
  // Highest salience keeps its outline when the cap bites — same rule as the
  // marker cut, and deterministic on ties by id so a re-render never flickers.
  passing.sort((x, y) {
    final s = y.candidate.salience.compareTo(x.candidate.salience);
    return s != 0 ? s : x.candidate.id.compareTo(y.candidate.id);
  });
  final kept = passing.length > maxOutlines ? passing.sublist(0, maxOutlines) : passing;
  return kept..sort((x, y) => y.screenExtentPx.compareTo(x.screenExtentPx));
}

/// `CandidateMarker`'s ring weight at its 32 px slot: `(1.4 + 1.6·s)·u`
/// with `u = size/24` — the outline uses the same coefficients so a notable
/// candidate's ring and its boundary read as one weight.
double outlineStrokeWidth(double salience) => 1.4 + 1.6 * salience;

/// `CandidateMarker`'s fill opacity is `0.25 + 0.55·s`; an area fill has to
/// sit under labels and the basemap, so it runs a fifth of that — a marginal
/// reserve is a tint, a notable one a wash, neither ever opaque.
double outlineFillOpacity(double salience) => (0.25 + 0.55 * salience) * 0.2;

/// Line and ring strokes carry the marker's opacity ramp directly.
double outlineStrokeOpacity(double salience) => 0.25 + 0.55 * salience;

/// A `FlutterMap` child: outlines for the polygon/line candidates in
/// [candidates] that pass the gates above for the current camera.
class CandidateGeometryLayer extends StatefulWidget {
  const CandidateGeometryLayer({
    super.key,
    required this.candidates,
    this.onCandidateTap,
    this.minScreenExtentPx = defaultMinScreenExtentPx,
    this.maxOutlines = defaultMaxOutlines,
  });

  /// 1.5× the 32 px marker slot: an outline that would not clear the pin it
  /// sits under adds nothing the pin is not already saying.
  static const defaultMinScreenExtentPx = 48.0;

  /// SPIKE-G's derived K for widget markers on a GPU desktop (~300); the
  /// outline cap mirrors it rather than inventing a second budget.
  static const defaultMaxOutlines = 300;

  final List<Candidate> candidates;
  final void Function(Candidate)? onCandidateTap;
  final double minScreenExtentPx;
  final int maxOutlines;

  @override
  State<CandidateGeometryLayer> createState() => _CandidateGeometryLayerState();
}

class _CandidateGeometryLayerState extends State<CandidateGeometryLayer> {
  final LayerHitNotifier<Candidate> _polygonHits = ValueNotifier(null);
  final LayerHitNotifier<Candidate> _lineHits = ValueNotifier(null);

  @override
  void dispose() {
    _polygonHits.dispose();
    _lineHits.dispose();
    super.dispose();
  }

  void _tap(LayerHitNotifier<Candidate> hits) {
    final values = hits.value?.hitValues;
    if (values == null || values.isEmpty) return;
    // Elements are drawn largest-first, so the last hit is the innermost.
    widget.onCandidateTap?.call(values.last);
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final c = PlotColors.of(context);
    final plan = planCandidateOutlines(
      widget.candidates,
      project: camera.latLngToScreenOffset,
      visible: camera.visibleBounds,
      minScreenExtentPx: widget.minScreenExtentPx,
      maxOutlines: widget.maxOutlines,
    );
    if (plan.isEmpty) return const SizedBox.shrink();

    final polygons = <Polygon<Candidate>>[];
    final lines = <Polyline<Candidate>>[];
    for (final outline in plan) {
      final s = outline.candidate.salience;
      switch (outline.geometry) {
        case CandidatePolygon(ring: final ring):
          polygons.add(Polygon(
            points: [for (final p in ring) ll.LatLng(p[1], p[0])],
            color: c.primary.withValues(alpha: outlineFillOpacity(s)),
            borderColor: c.primary.withValues(alpha: outlineStrokeOpacity(s)),
            borderStrokeWidth: outlineStrokeWidth(s),
            hitValue: outline.candidate,
          ));
        case CandidateLine(coords: final coords):
          lines.add(Polyline(
            points: [for (final p in coords) ll.LatLng(p[1], p[0])],
            color: c.primary.withValues(alpha: outlineStrokeOpacity(s)),
            strokeWidth: outlineStrokeWidth(s),
            hitValue: outline.candidate,
          ));
      }
    }

    // Two layers, lines over polygons: a byway crossing a reserve is the
    // narrower target and should win the tap where they overlap. A tap that
    // hits no element falls through to the map (`onMapTap`) as before.
    return Stack(fit: StackFit.expand, children: [
      if (polygons.isNotEmpty)
        GestureDetector(
          onTap: () => _tap(_polygonHits),
          child: PolygonLayer(polygons: polygons, hitNotifier: _polygonHits),
        ),
      if (lines.isNotEmpty)
        GestureDetector(
          onTap: () => _tap(_lineHits),
          child: PolylineLayer(polylines: lines, hitNotifier: _lineHits),
        ),
    ]);
  }
}
