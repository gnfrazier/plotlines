/// Issue #589 (ARCH D71) — a node the route must reach.
///
/// A passage's nodes are annotations: a rest stop, a waypoint, a POI hung on
/// the day. The solver never reads them. What it reads is `Segment.via`, the
/// ordered list of points a re-solve goes through (FR8a / A9, `routing/
/// solve.py`'s `start → [via…] → end`). Before #589 the only ways into `via`
/// were New Route's map taps and Compose's spine editor, so an Author who
/// placed a node after generating a route had no way to make the route go
/// there.
///
/// "Route through this" is a per-node choice that puts the node's coordinate
/// into `via`. The link is the coordinate itself, the same coupling the spine
/// editor already uses for anchors, so the payload schema does not change: a
/// node routes through exactly when its coordinate is one of the passage's
/// via points. Everything here is pure, and the notifier is the one caller
/// that writes the result back.
library;

import 'alternate_draft.dart' show snapToPath;
import 'anchor.dart';
import 'json_utils.dart';
import 'node.dart';
import 'segment.dart';

bool sameCoord(Coord a, Coord b) => a[0] == b[0] && a[1] == b[1];

/// Issue #626 — a passage built from placed nodes: it has no start or end of
/// its own, so its route-through points are the whole route, first to last.
/// Placing a node on a route day with no passage creates one of these, and
/// the Author orders the points from the rail's ROUTE THROUGH list.
bool routesFromNodes(Segment segment) =>
    segment.start == null && segment.end == null && segment.shape == 'point_to_point';

/// What a solve of a node-built passage sends: its first route-through point
/// as the start, its last as the end, and the ones between as via. Null when
/// [segment] is not node-built or has fewer than two points to route between.
({Coord start, Coord end, List<Coord> via})? nodeRouteSolveInputs(Segment segment) {
  if (!routesFromNodes(segment) || segment.via.length < 2) return null;
  final via = segment.via;
  return (start: via.first, end: via.last, via: via.sublist(1, via.length - 1));
}

/// Does [node] route through — is its coordinate one of [segment]'s via points?
bool nodeRoutesThrough(Segment segment, Node node) =>
    segment.via.any((v) => sameCoord(v, node.coord));

/// Where [c] falls along [segment], as a sort key: metres along the solved line
/// when there is one, else along the straight start→end chord of an unsolved
/// point-to-point passage. `null` when neither exists (an unsolved loop has no
/// line to measure along).
double? _orderKey(Segment segment, Coord c) {
  final line = segment.geometry?.coordinates;
  if (line != null && line.length >= 2) return snapToPath(line, c)?.alongM;
  final start = segment.start;
  final end = segment.end;
  if (start != null && end != null && !sameCoord(start, end)) {
    return snapToPath([start, end], c)?.alongM;
  }
  return null;
}

/// [segment]'s via list with [c] added where it falls along the day.
///
/// Only the new point is placed. The points already there keep the order
/// they have, because the Author may have reordered them on purpose (the
/// rail's via list). [c] goes in after the last existing point that lies
/// before it, so it falls among them by position. A passage with no line to
/// measure against appends it, and the Author can reorder from the rail.
/// Adding a point already in the list returns the list unchanged.
List<Coord> viaWithInserted(Segment segment, Coord c) {
  final via = segment.via;
  if (via.any((v) => sameCoord(v, c))) return via;
  final key = _orderKey(segment, c);
  if (key == null) return [...via, c];
  var insertAt = 0;
  for (var i = 0; i < via.length; i++) {
    final k = _orderKey(segment, via[i]);
    if (k != null && k <= key) insertAt = i + 1;
  }
  return [...via.sublist(0, insertAt), c, ...via.sublist(insertAt)];
}

/// [via] with every point equal to [c] removed.
List<Coord> viaWithout(List<Coord> via, Coord c) => [
      for (final v in via)
        if (!sameCoord(v, c)) v,
    ];

/// [via] with the point at [from] replaced by [to] in place, so moving a
/// routed-through node keeps its position in the order. Unchanged when [from]
/// is not a via point.
List<Coord> viaWithMoved(List<Coord> via, Coord from, Coord to) => [
      for (final v in via)
        if (sameCoord(v, from)) to else v,
    ];

/// #589 — within this distance of the solved line, a via point counts as
/// reached. Point-to-point snaps each via point to the nearest graph node
/// (`graph/loader.py::nearest_node`, guarded at 3 km), and the solved line runs
/// through that node, so a point placed on a road sits on the line or within a
/// few tens of metres of it once the simplified graph's chords are allowed
/// for. A point the line passes farther away than this has been reached in
/// the solver's terms (its snapped node is on the path), but not in the
/// Author's. That is why it is reported by its own distance rather than a
/// bare yes from `solve.hit_via`, which only loops set at all.
const double kViaReachedM = 100;

/// One via point and whether the solved line reaches it.
typedef ViaReach = ({
  Coord coord,
  String label,

  /// Great-circle metres from the point to the nearest place on the solved
  /// line. `null` when the passage has no solved line.
  double? offsetM,
});

extension ViaReachX on ViaReach {
  bool get reached => offsetM != null && offsetM! <= kViaReachedM;
}

/// What a via point is called in the rail. A routed-through node gives its own
/// name, then its kind. A promoted anchor (Compose's spine) gives the anchor's
/// title. A bare point (a New Route map tap) is numbered by its position.
String viaLabel(Segment segment, Coord v, int index, {List<Anchor> anchors = const []}) {
  for (final n in segment.nodes) {
    if (sameCoord(n.coord, v)) {
      final kind = n.kind.wireValue.replaceAll('_', ' ');
      final title = n.title;
      if (title == null || title.isEmpty) return '${kind[0].toUpperCase()}${kind.substring(1)}';
      return title;
    }
  }
  for (final a in anchors) {
    if (sameCoord(a.coord, v)) return a.title ?? 'Untitled place';
  }
  return 'Point ${index + 1}';
}

/// Each of [segment]'s via points with its label and its distance from the
/// solved line, in via order.
List<ViaReach> viaReach(Segment segment, {List<Anchor> anchors = const []}) {
  final line = segment.geometry?.coordinates;
  return [
    for (var i = 0; i < segment.via.length; i++)
      (
        coord: segment.via[i],
        label: viaLabel(segment, segment.via[i], i, anchors: anchors),
        offsetM: line == null ? null : snapToPath(line, segment.via[i])?.offsetM,
      ),
  ];
}
