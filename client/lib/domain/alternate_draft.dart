/// FR20 [AMENDED v2.0] / C4, Flow 11 (issue #324) — the map gesture that makes
/// an alternate, before any card opens.
///
/// Creating an alternate used to be: name it, declare its intent, then fill in
/// every property of a path that had not been drawn — the card's own status
/// line said `not drawn`. Nothing in it could answer where the alternate was,
/// where it left the day, where it came back, or what it contained, because
/// none of that had been decided. So the order inverts: the Author works on the
/// route first and marks the divergence, and the card opens afterwards as an
/// inspector for something that exists.
///
/// [AlternateDraft] is that gesture as a value: the parent passage's solved
/// line, the fork, the rejoin, and any points shaping the path between them.
/// It is deliberately pure and widget-free — the Route tab holds one in state
/// and feeds it taps, and every rule about what makes a drawable alternate is
/// asserted here rather than in a widget test.
///
/// **Not part of the trip payload schema.** A draft is authoring state that
/// exists between the first tap and [AlternateDraft.geometry]; what reaches the
/// payload is the `$defs/alternate` the draft produces, whose `geometry` has
/// the two coordinates `$defs/line_string` requires. An alternate with an empty
/// line-string was never a valid payload — `minItems: 2` — which is the second
/// reason `not drawn` had to stop being an authorable state.
library;

import 'dart:math' as math;

import 'json_utils.dart';
import 'passage_sequence.dart';
import 'segment.dart';

/// Where a tap landed relative to a path: the foot of the perpendicular
/// ([point]), how far along the path that foot sits ([alongM]), and how far the
/// tap itself was from the line ([offsetM]).
///
/// [alongM] is what makes a fork nameable — `LEAVES MI 6.2` is a distance along
/// the day, not a coordinate — and it is why this returns more than
/// `nearestPointOnPath` did.
typedef PathSnap = ({Coord point, double alongM, double offsetM});

/// The point on [path] closest to [from], with its distance along the path.
/// `null` when [path] has fewer than two vertices — there is no line to measure
/// against, which is a different answer from "zero away".
///
/// Local planar frame centred on the query point: one degree of latitude and
/// one of longitude are not the same ground distance, so x is scaled by
/// cos(lat) to make the two comparable over the short spans a snap covers. The
/// reported distances are then real great-circle measurements via [haversineM],
/// so they agree with every other distance the app shows.
PathSnap? snapToPath(List<Coord> path, Coord from) {
  if (path.length < 2) return null;

  final kx = math.cos(from[1] * math.pi / 180);
  double px(Coord c) => (c[0] - from[0]) * kx;
  double py(Coord c) => c[1] - from[1];

  Coord? best;
  var bestSq = double.infinity;
  var bestAlong = 0.0;
  var travelled = 0.0;
  for (var i = 1; i < path.length; i++) {
    final ax = px(path[i - 1]), ay = py(path[i - 1]);
    final bx = px(path[i]), by = py(path[i]);
    final dx = bx - ax, dy = by - ay;
    final lenSq = dx * dx + dy * dy;
    // t is the projection of the origin (the query point) onto this leg,
    // clamped so the foot never runs past either vertex.
    final t = lenSq == 0 ? 0.0 : (-(ax * dx + ay * dy) / lenSq).clamp(0.0, 1.0);
    final fx = ax + dx * t, fy = ay + dy * t;
    final sq = fx * fx + fy * fy;
    final legM = haversineM(path[i - 1], path[i]);
    if (sq < bestSq) {
      bestSq = sq;
      // Back to lon/lat: the foot is the same fraction `t` along the leg in
      // real coordinates — the cos(lat) scaling only governed the choice of
      // `t`, not the interpolation.
      best = [
        path[i - 1][0] + (path[i][0] - path[i - 1][0]) * t,
        path[i - 1][1] + (path[i][1] - path[i - 1][1]) * t,
      ];
      bestAlong = travelled + legM * t;
    }
    travelled += legM;
  }
  if (best == null) return null;
  return (point: best, alongM: bestAlong, offsetM: haversineM(from, best));
}

/// Total great-circle length of [path], in metres. Zero for a path with fewer
/// than two vertices — nothing to measure, not an error.
double pathLengthM(List<Coord> path) {
  var total = 0.0;
  for (var i = 1; i < path.length; i++) {
    total += haversineM(path[i - 1], path[i]);
  }
  return total;
}

/// The point [targetM] along [path], linearly interpolated between the two
/// vertices it falls between. Clamps to the first/last vertex outside the
/// path's range rather than extrapolating; `[0, 0]` for an empty path.
///
/// The one definition of "where is this distance on the line" — `geo_utils`'
/// `pointAtDistance` (which places a cue that carries only `distanceAlongM`)
/// delegates here, so a cue and a fork never disagree about the same metre.
Coord pointAtDistanceOnPath(List<Coord> path, double targetM) {
  if (path.isEmpty) return const [0, 0];
  if (path.length == 1 || targetM <= 0) return path.first;
  var cumulative = 0.0;
  for (var i = 1; i < path.length; i++) {
    final legM = haversineM(path[i - 1], path[i]);
    if (cumulative + legM >= targetM) {
      final frac = legM <= 0 ? 0.0 : ((targetM - cumulative) / legM).clamp(0.0, 1.0);
      return [
        path[i - 1][0] + (path[i][0] - path[i - 1][0]) * frac,
        path[i - 1][1] + (path[i][1] - path[i - 1][1]) * frac,
      ];
    }
    cumulative += legM;
  }
  return path.last;
}

/// The stretch of [path] between [fromM] and [toM] along it, with the
/// interpolated endpoints at either end and every vertex in between. Used to
/// draw the piece of the day an alternate stands in for — the Author should see
/// what is being replaced, not only what is being added.
List<Coord> pathBetween(List<Coord> path, double fromM, double toM) {
  if (path.length < 2) return const [];
  final lo = fromM <= toM ? fromM : toM;
  final hi = fromM <= toM ? toM : fromM;
  final out = <Coord>[pointAtDistanceOnPath(path, lo)];
  var cumulative = 0.0;
  for (var i = 1; i < path.length; i++) {
    cumulative += haversineM(path[i - 1], path[i]);
    // A millimetre of tolerance at either end: a mark placed exactly on a
    // vertex would otherwise emit that vertex twice, once interpolated and
    // once for itself.
    if (cumulative - lo > 0.001 && hi - cumulative > 0.001) out.add(path[i]);
  }
  out.add(pointAtDistanceOnPath(path, hi));
  return out;
}

/// What the gesture is asking for next.
enum AlternateDraftStage {
  /// Tap the point on the route where the alternate leaves it.
  fork,

  /// Tap the point on the route where it comes back.
  rejoin,

  /// Fork and rejoin are set; further taps shape the path between them, and
  /// the alternate can be created at any time.
  shape,
}

/// A divergence being drawn on a passage's solved line: fork, rejoin, and the
/// points shaping the path between them.
///
/// Taps in the [AlternateDraftStage.fork] and [AlternateDraftStage.rejoin]
/// stages are snapped onto the route — a fork that is merely *near* the line
/// has no distance along the day and would leave `diverges_at_m` a guess. Taps
/// in [AlternateDraftStage.shape] are taken where they land: that is the path
/// itself, and it is authored geometry, not a solve.
class AlternateDraft {
  const AlternateDraft({
    required this.route,
    this.fork,
    this.rejoin,
    this.shape = const [],
  });

  /// The parent passage's solved geometry — the line being diverged from.
  final List<Coord> route;

  /// Where the alternate leaves [route], snapped onto it.
  final PathSnap? fork;

  /// Where the alternate returns to [route], snapped onto it.
  final PathSnap? rejoin;

  /// Author-placed points between [fork] and [rejoin], in tap order. Empty is
  /// legitimate — fork and rejoin alone are a straight divergence, which is a
  /// path the Author drew and can reshape.
  final List<Coord> shape;

  /// Whether a passage can be diverged from at all. A day with no solved line
  /// has nothing to leave and nothing to rejoin, so the gesture is not offered
  /// (rather than offered and then refused).
  static bool canDraftOn(List<Coord>? route) => route != null && route.length >= 2;

  /// A fresh draft on [route].
  factory AlternateDraft.on(List<Coord> route) => AlternateDraft(route: route);

  AlternateDraftStage get stage {
    if (fork == null) return AlternateDraftStage.fork;
    if (rejoin == null) return AlternateDraftStage.rejoin;
    return AlternateDraftStage.shape;
  }

  /// The draft after a tap at [coord]. Fork and rejoin snap to [route]; shape
  /// points are kept where they were placed. A tap that cannot snap (no line)
  /// leaves the draft unchanged.
  AlternateDraft tap(Coord coord) {
    switch (stage) {
      case AlternateDraftStage.fork:
        final snap = snapToPath(route, coord);
        return snap == null ? this : _copy(fork: snap);
      case AlternateDraftStage.rejoin:
        final snap = snapToPath(route, coord);
        return snap == null ? this : _copy(rejoin: snap);
      case AlternateDraftStage.shape:
        return _copy(shape: [...shape, coord]);
    }
  }

  /// The draft with the most recent placement removed — the last shape point,
  /// else the rejoin, else the fork. A no-op on an empty draft.
  AlternateDraft undoLast() {
    if (shape.isNotEmpty) {
      return AlternateDraft(
        route: route,
        fork: fork,
        rejoin: rejoin,
        shape: shape.sublist(0, shape.length - 1),
      );
    }
    if (rejoin != null) return AlternateDraft(route: route, fork: fork);
    return AlternateDraft(route: route);
  }

  AlternateDraft _copy({PathSnap? fork, PathSnap? rejoin, List<Coord>? shape}) =>
      AlternateDraft(
        route: route,
        fork: fork ?? this.fork,
        rejoin: rejoin ?? this.rejoin,
        shape: shape ?? this.shape,
      );

  /// Distance along the parent passage where the alternate leaves it — the
  /// earlier of the two marks. An Author who taps the rejoin first has drawn
  /// the same divergence walked backwards, so the two marks are ordered here
  /// rather than refused.
  double? get divergesAtM {
    final f = fork?.alongM, r = rejoin?.alongM;
    if (f == null || r == null) return f;
    return f <= r ? f : r;
  }

  /// Distance along the parent passage where the alternate rejoins it — the
  /// later of the two marks.
  double? get rejoinsAtM {
    final f = fork?.alongM, r = rejoin?.alongM;
    if (f == null || r == null) return null;
    return f <= r ? r : f;
  }

  /// A fork and a rejoin closer together than this describe the same point on
  /// the route: a divergence with nowhere to diverge. One metre is well under
  /// the resolution of any tap on any usable zoom, so this only ever catches a
  /// double-tap on the same spot.
  static const double minSpanM = 1.0;

  /// Why this draft cannot be made into an alternate yet, in one line, or
  /// `null` when it can. The gesture surface says this rather than disabling a
  /// button with no explanation.
  String? get blocker {
    if (!canDraftOn(route)) {
      return 'This passage has no solved route to diverge from yet.';
    }
    if (fork == null) return 'Tap the route where this path leaves it.';
    if (rejoin == null) return 'Tap the route where this path comes back.';
    if ((rejoinsAtM! - divergesAtM!) < minSpanM) {
      return 'The fork and the rejoin are the same point on the route.';
    }
    return null;
  }

  bool get isComplete => blocker == null;

  /// The alternate's own path: the fork, the Author's shaping points in order,
  /// and the rejoin. Ordered from [divergesAtM] to [rejoinsAtM], so a
  /// divergence marked back-to-front still reads forwards along the day.
  ///
  /// `authored`, never `solved` — the Author drew this line, and a consumer
  /// that cannot tell the two apart presents a hand-drawn line with a solved
  /// line's authority (`$defs/line_string`).
  LineString? get geometry {
    if (!isComplete) return null;
    final forward = fork!.alongM <= rejoin!.alongM;
    final ends = forward ? [fork!.point, rejoin!.point] : [rejoin!.point, fork!.point];
    final middle = forward ? shape : shape.reversed.toList();
    return LineString(
      coordinates: [ends.first, ...middle, ends.last],
      source: 'authored',
    );
  }

  /// Everything placed so far, in drawing order — what the map shows while the
  /// gesture is still in progress. Once the draft is complete this is
  /// [geometry]'s coordinates, so the line the Author is looking at is the line
  /// that gets saved.
  List<Coord> get previewLine =>
      geometry?.coordinates ??
      [
        if (fork != null) fork!.point,
        ...shape,
        if (rejoin != null) rejoin!.point,
      ];

  /// The mark that reads as "leaves here" — the earlier of the two along the
  /// route, or the only one placed so far.
  Coord? get leavesPoint {
    final f = fork, r = rejoin;
    if (f == null) return null;
    if (r == null) return f.point;
    return f.alongM <= r.alongM ? f.point : r.point;
  }

  /// The mark that reads as "rejoins here" — the later of the two.
  Coord? get rejoinsPoint {
    final f = fork, r = rejoin;
    if (f == null || r == null) return null;
    return f.alongM <= r.alongM ? r.point : f.point;
  }

  /// The stretch of the parent passage this alternate stands in for.
  List<Coord> get canonStretch {
    final from = divergesAtM, to = rejoinsAtM;
    if (from == null || to == null) return const [];
    return pathBetween(route, from, to);
  }

  /// How long the drawn path is, in metres. Null until it is complete.
  double? get alternateDistanceM {
    final g = geometry;
    return g == null ? null : pathLengthM(g.coordinates);
  }

  /// How long the piece of the day it replaces is, in metres.
  double? get canonDistanceM {
    final from = divergesAtM, to = rejoinsAtM;
    if (from == null || to == null) return null;
    return to - from;
  }

  /// Drawn length minus replaced length: negative is shorter than the day as
  /// written, positive is longer. This is a measurement of the line the Author
  /// drew, not of a solve — the solver has not run on it, and every surface
  /// showing it says which it is.
  double? get deltaM {
    final a = alternateDistanceM, c = canonDistanceM;
    return (a == null || c == null) ? null : a - c;
  }

  /// The `kind` this shape implies — `bypass` for the direct way, `extension`
  /// for the long way round. A default the Author can override at naming: the
  /// drawn line already answers "shorter or longer", so there is no reason to
  /// ask first and measure second.
  String get impliedKind => (deltaM ?? 0) < 0 ? 'bypass' : 'extension';
}

/// What qualifies the numbers on a path the engine has never seen: they are
/// the length of the line the Author drew, not a solve. Said once here because
/// the naming dialog (over an [AlternateDraft], which is unsolved by
/// definition) and the card (over an [Alternate] that may be) both say it, and
/// a drawn line must never wear a solved line's authority on either.
const String kAlternateDrawnNotSolvedNote =
    'Measured off the line as drawn, not solved.';

/// The same three measurements, read back off a saved [Alternate] — what the
/// branch card shows in place of the old `not drawn` line: where it leaves,
/// where it comes back, and what it costs against the day as written.
///
/// These live here, next to the draft that produced them, so the number the
/// Author saw while drawing and the number the card shows afterwards come from
/// one definition.
extension AlternateGeometryReadout on Alternate {
  /// Length of the drawn path. Prefers the solved [Alternate.metrics] when a
  /// solve has filled them in; falls back to measuring the line itself, which
  /// is what an Author-drawn path has until it is solved.
  double get drawnDistanceM =>
      metrics?.distanceM ?? pathLengthM(geometry.coordinates);

  /// Length of the stretch of the parent passage this stands in for — the gap
  /// between [Alternate.divergesAtM] and [Alternate.rejoinsAtM]. Null when
  /// either mark is missing (an alternate saved before #324 made them part of
  /// the gesture).
  double? get canonSpanM {
    final from = divergesAtM, to = rejoinsAtM;
    return (from == null || to == null) ? null : to - from;
  }

  /// Drawn length minus replaced length: negative is shorter than the day as
  /// written, positive is longer.
  double? get distanceDeltaM {
    final span = canonSpanM;
    return span == null ? null : drawnDistanceM - span;
  }

  /// Whether this alternate knows where it leaves and rejoins the passage.
  /// False only for one saved before the marks were part of creating it.
  bool get hasForkAndRejoin => divergesAtM != null && rejoinsAtM != null;

  /// Whether the engine has ever solved this path. False means every number
  /// on it is measured off the line the Author drew — which is honest, and a
  /// different statement from [isStale].
  bool get isSolved => solve != null;

  /// FR140 / Q3 (issue #344) — the alternate's derived half describes a path
  /// that has moved. Never true for an unsolved alternate: there is nothing
  /// derived to invalidate.
  bool get isStale => solve?.stale ?? false;

  /// Flow 11 §06 — "its distances are the ones it was solved with, and they
  /// say so wherever they appear." The one line that qualifies an alternate's
  /// numbers, so the sentence is not written three times and three ways on the
  /// three surfaces that show them. Null when the numbers need no qualifying:
  /// solved, and still describing the path they were solved for.
  ///
  /// Deliberately not a failure and deliberately not a template slot for a
  /// timestamp — the *when* is data and renders as data, in the Author's own
  /// date format, beside this (ARCH D49: a display format never reaches
  /// stored data, and an ISO string never reaches a sentence).
  String? get provenanceNote {
    if (!isSolved) return kAlternateDrawnNotSolvedNote;
    if (!isStale) return null;
    return 'These distances are the ones this path was solved with, before it moved.';
  }
}
