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
//
// The projection itself moved to `domain/alternate_draft.dart`'s [snapToPath]
// under issue #324, which needed the same foot *plus* its distance along the
// line to name a fork ("LEAVES MI 6.2"). One projection, two callers.
library;

import '../../domain/domain.dart';

/// The point on [path] closest to [from], and the great-circle metres between
/// them. `null` when [path] has fewer than two vertices — there is no line to
/// measure against, which is a different answer from "zero away".
({Coord point, double distanceM})? nearestPointOnPath(List<Coord> path, Coord from) {
  final snap = snapToPath(path, from);
  return snap == null ? null : (point: snap.point, distanceM: snap.offsetM);
}
