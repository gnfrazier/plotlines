// #322 — the small amount of geometry the Route tab needs to relate an
// authored node to the line it was placed on: where on the polyline a node's
// nearest point sits, and how far off the line that is.
//
// This is deliberately client-only and approximate. The offsets in play are
// tens of metres — a mis-click, or a place a step off the trail — so each
// polyline segment is projected in a local equirectangular frame (longitude
// scaled by cos(lat) around the query point) and the perpendicular foot is
// clamped to the segment. The reported distance is then a real great-circle
// measurement via [haversineM], so it agrees with every other distance the
// app shows. Nothing here feeds the solver; a `via` node that should actually
// bend the route marks the segment stale (Q3/FR140) and a re-solve does the
// real routing.
library;

import 'dart:math' as math;

import '../../domain/domain.dart';

/// The point on [path] closest to [from], and the great-circle metres between
/// them. `null` when [path] has fewer than two vertices — there is no line to
/// measure against, which is a different answer from "zero away".
({Coord point, double distanceM})? nearestPointOnPath(List<Coord> path, Coord from) {
  if (path.length < 2) return null;

  // Local planar frame centred on the query point. 1 degree of latitude and
  // 1 degree of longitude are not the same ground distance; scaling x by
  // cos(lat) makes the two comparable for the short spans this is used on.
  final lat0 = from[1] * math.pi / 180;
  final kx = math.cos(lat0);
  double px(Coord c) => (c[0] - from[0]) * kx;
  double py(Coord c) => c[1] - from[1];

  Coord? best;
  var bestSq = double.infinity;
  for (var i = 1; i < path.length; i++) {
    final ax = px(path[i - 1]), ay = py(path[i - 1]);
    final bx = px(path[i]), by = py(path[i]);
    final dx = bx - ax, dy = by - ay;
    final lenSq = dx * dx + dy * dy;
    // t is the projection of the origin (the query point) onto the segment,
    // clamped so the foot never runs past either vertex.
    final t = lenSq == 0 ? 0.0 : (-(ax * dx + ay * dy) / lenSq).clamp(0.0, 1.0);
    final fx = ax + dx * t, fy = ay + dy * t;
    final sq = fx * fx + fy * fy;
    if (sq < bestSq) {
      bestSq = sq;
      // Back to lon/lat: the foot is the same fraction `t` along the segment
      // in real coordinates — the cos(lat) scaling only governed the choice
      // of `t`, not the interpolation.
      best = [
        path[i - 1][0] + (path[i][0] - path[i - 1][0]) * t,
        path[i - 1][1] + (path[i][1] - path[i - 1][1]) * t,
      ];
    }
  }
  if (best == null) return null;
  return (point: best, distanceM: haversineM(from, best));
}
