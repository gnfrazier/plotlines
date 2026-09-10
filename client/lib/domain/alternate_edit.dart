/// FR20 [AMENDED v2.0] / C4 / FR140 / Q3, Flow 11 §03–§04 and §06 (issue #344)
/// — moving an alternate that already exists.
///
/// #324 made *creating* an alternate a map gesture and turned the card into an
/// inspector. It left the card leading with `WHERE IT LEAVES AND REJOINS` and
/// no way to change either mark: the recourse for a fork placed 400 m too early
/// was to delete the alternate and draw it again, losing the name, the note,
/// the attached anchors, the narration and the reveal along with the geometry —
/// exactly the authored work the convert prompt is careful never to destroy
/// silently. The canvas puts a **`Move on the map`** action directly under that
/// block on both the branch and the accommodation card; this is the value it
/// runs on.
///
/// [AlternateEdit] is [AlternateDraft]'s counterpart for a path that exists.
/// Two things separate them, and both come from that:
///
///  * A draft is placed in order (fork, then rejoin, then shaping points). An
///    edit is **direct manipulation** — every handle is already placed, so the
///    Author grabs the one they mean and puts it somewhere else. Adding and
///    removing a shaping point are part of that vocabulary, because a path
///    whose interior cannot change is not reshapeable, only re-endable.
///  * A draft has nothing to invalidate. An edit does: an alternate that has
///    been solved carries `metrics` and `elevation` derived from the line as it
///    was, and moving a handle makes those describe a path that no longer
///    exists. Per FR140/D-O that is **stale, not destroyed** — no prompt,
///    nothing re-solves on its own ([staleAfterMove] is the whole of the rule,
///    and [CurrentTripNotifier.updateAlternateGeometry] is where it is applied).
///
/// Pure and widget-free, like the draft: the Route tab holds one in state and
/// feeds it taps, and every rule about what a moved handle does is asserted
/// here rather than in a widget test.
library;

import 'alternate_draft.dart';
import 'json_utils.dart';
import 'passage_sequence.dart';
import 'segment.dart';

/// Which handle of a drawn alternate the next tap moves.
enum AlternateHandle {
  /// Where the path leaves the parent passage. Snaps onto the passage's line.
  fork,

  /// Where it comes back. Snaps onto the passage's line.
  rejoin,

  /// One of the points shaping the path between them, named by
  /// [AlternateEdit.handleIndex]. Taken where it lands — that is the drawn
  /// path, not a solve.
  shapePoint,

  /// A shaping point that does not exist yet. The tap inserts it at the place
  /// along the drawn path where it was put, never at the end: a point appended
  /// after the rejoin would fold the path back on itself.
  newShapePoint,
}

/// The index [path] would insert [coord] at to keep the drawn line in order —
/// the leg whose stretch of the path the tap falls on, expressed as a position
/// in the interior (shaping-point) list.
///
/// Appending was the obvious implementation and the wrong one: a shaping point
/// dropped in the middle of a long path would jump to the far end and drag the
/// line across the map with it.
int shapeInsertionIndex(List<Coord> drawnPath, Coord coord) {
  if (drawnPath.length < 2) return 0;
  final snap = snapToPath(drawnPath, coord);
  if (snap == null) return 0;
  var travelled = 0.0;
  for (var i = 1; i < drawnPath.length; i++) {
    travelled += haversineM(drawnPath[i - 1], drawnPath[i]);
    if (snap.alongM <= travelled) return i - 1;
  }
  // Past the last vertex: after every interior point, i.e. just before the
  // rejoin. `drawnPath` is [fork, ...shape, rejoin], so that is `length - 2`.
  return drawnPath.length - 2;
}

/// An existing alternate's geometry being moved on the map.
///
/// Nothing here touches the trip. The Author works against this value until
/// they are done, and only then does one call reach
/// [CurrentTripNotifier.updateAlternateGeometry] — so backing out is free and
/// the trip never sees a half-moved fork.
class AlternateEdit {
  const AlternateEdit({
    required this.alternateId,
    required this.route,
    required this.fork,
    required this.rejoin,
    this.shape = const [],
    this.handle,
    this.handleIndex = 0,
    this.wasSolved = false,
    this.moved = false,
  });

  /// The alternate being moved.
  final String alternateId;

  /// The parent passage's solved line — what the fork and the rejoin are
  /// measured along, and what they snap to.
  final List<Coord> route;

  /// Where the path leaves [route]. Null only for an alternate saved before
  /// #324 made the marks part of creating one: it has a drawn line but no
  /// `diverges_at_m`, so the Author places the mark for the first time here
  /// rather than the app inventing a distance for them.
  final PathSnap? fork;

  /// Where it comes back. Null under the same one condition as [fork].
  final PathSnap? rejoin;

  /// The points shaping the path between them, in path order.
  final List<Coord> shape;

  /// Which handle the next tap moves. Null means no handle is grabbed and a
  /// tap on the map does nothing — panning a map should not silently drag the
  /// last thing that was selected.
  final AlternateHandle? handle;

  /// Which shaping point [handle] names, for
  /// [AlternateHandle.shapePoint] / [AlternateHandle.newShapePoint].
  final int handleIndex;

  /// Whether the alternate had been solved when the edit opened. The stale
  /// rule reads this rather than the live [Alternate], because staleness is a
  /// statement about the solve that produced the numbers now on screen.
  final bool wasSolved;

  /// Whether any handle has actually moved. A `Move on the map` the Author
  /// opens and closes again changes nothing and must not mark anything stale —
  /// staleness is caused by an edit, not by looking.
  final bool moved;

  /// An edit session over [alternate], on the passage line [route].
  ///
  /// The handles are read back off what was saved: the drawn line's first and
  /// last coordinates are the fork and the rejoin, its interior is the shaping
  /// points, and `diverges_at_m` / `rejoins_at_m` are the distances along the
  /// passage those two marks were snapped to. Where those two are absent
  /// (an alternate drawn before #324) the marks are left unplaced rather than
  /// re-derived — projecting the endpoints back onto the line would invent a
  /// `diverges_at_m` the Author never authored, and this surface's whole job is
  /// to let them place it.
  factory AlternateEdit.of(Alternate alternate, List<Coord> route) {
    final coords = alternate.geometry.coordinates;
    final diverges = alternate.divergesAtM, rejoins = alternate.rejoinsAtM;
    return AlternateEdit(
      alternateId: alternate.id,
      route: route,
      fork: diverges == null
          ? null
          : (point: coords.first, alongM: diverges, offsetM: 0.0),
      rejoin: rejoins == null
          ? null
          : (point: coords.last, alongM: rejoins, offsetM: 0.0),
      shape: coords.length <= 2 ? const [] : coords.sublist(1, coords.length - 1),
      wasSolved: alternate.solve != null,
    );
  }

  /// Whether [alternate] can be moved at all: there has to be a passage line
  /// under it to snap the two marks onto. Offered rather than refused, the
  /// same rule [AlternateDraft.canDraftOn] applies to drawing one.
  static bool canMoveOn(List<Coord>? route) => AlternateDraft.canDraftOn(route);

  AlternateEdit _copy({
    PathSnap? fork,
    PathSnap? rejoin,
    List<Coord>? shape,
    Object? handle = _unset,
    int? handleIndex,
    bool? moved,
  }) =>
      AlternateEdit(
        alternateId: alternateId,
        route: route,
        fork: fork ?? this.fork,
        rejoin: rejoin ?? this.rejoin,
        shape: shape ?? this.shape,
        handle: identical(handle, _unset) ? this.handle : handle as AlternateHandle?,
        handleIndex: handleIndex ?? this.handleIndex,
        wasSolved: wasSolved,
        moved: moved ?? this.moved,
      );

  static const Object _unset = Object();

  /// Grab [handle] (optionally the [index]th shaping point). Nothing has moved
  /// yet — the next tap is what moves it.
  AlternateEdit grab(AlternateHandle handle, {int index = 0}) =>
      _copy(handle: handle, handleIndex: index);

  /// Let go of whatever is grabbed, so a tap on the map does nothing.
  AlternateEdit release() => _copy(handle: null);

  /// The edit after a tap at [coord]. Fork and rejoin snap onto [route] — a
  /// mark merely *near* the line has no distance along the day and would leave
  /// `diverges_at_m` a guess, which is the same rule that governs drawing one.
  /// Shaping points are taken where they land.
  ///
  /// A tap with nothing grabbed is deliberately a no-op.
  AlternateEdit tap(Coord coord) {
    switch (handle) {
      case null:
        return this;
      case AlternateHandle.fork:
        final snap = snapToPath(route, coord);
        return snap == null ? this : _copy(fork: snap, moved: true);
      case AlternateHandle.rejoin:
        final snap = snapToPath(route, coord);
        return snap == null ? this : _copy(rejoin: snap, moved: true);
      case AlternateHandle.shapePoint:
        if (handleIndex < 0 || handleIndex >= shape.length) return this;
        final next = [...shape]..[handleIndex] = coord;
        return _copy(shape: next, moved: true);
      case AlternateHandle.newShapePoint:
        final at = shapeInsertionIndex(previewLine, coord).clamp(0, shape.length);
        final next = [...shape]..insert(at, coord);
        // Grab the point that was just made: the Author who placed it slightly
        // wrong should be able to move it without hunting for it in a list.
        return _copy(
          shape: next,
          handle: AlternateHandle.shapePoint,
          handleIndex: at,
          moved: true,
        );
    }
  }

  /// Take the grabbed shaping point out of the path. Only a shaping point can
  /// go: the fork and the rejoin are what make the alternate a divergence
  /// rather than a second unrelated line, so removing one is deleting the
  /// alternate, which is a different (confirming) action on the card.
  AlternateEdit removeGrabbedShapePoint() {
    if (handle != AlternateHandle.shapePoint) return this;
    if (handleIndex < 0 || handleIndex >= shape.length) return this;
    final next = [...shape]..removeAt(handleIndex);
    return _copy(shape: next, handle: null, moved: true);
  }

  /// Distance along the parent passage where the moved path leaves it — the
  /// earlier of the two marks. Ordering rather than refusing means an Author
  /// who drags the fork past the rejoin has walked the same divergence
  /// backwards, not broken it.
  double? get divergesAtM {
    final f = fork?.alongM, r = rejoin?.alongM;
    if (f == null || r == null) return f;
    return f <= r ? f : r;
  }

  /// Distance along the parent passage where it rejoins — the later of the two.
  double? get rejoinsAtM {
    final f = fork?.alongM, r = rejoin?.alongM;
    if (f == null || r == null) return null;
    return f <= r ? r : f;
  }

  /// Why this edit cannot be saved yet, in one line, or `null` when it can.
  /// The same rule [AlternateDraft.blocker] applies, and said the same way:
  /// the surface explains rather than disabling a button in silence.
  String? get blocker {
    if (!canMoveOn(route)) {
      return 'This passage has no solved route to measure the marks against.';
    }
    if (fork == null) return 'Tap the route where this path leaves it.';
    if (rejoin == null) return 'Tap the route where this path comes back.';
    if ((rejoinsAtM! - divergesAtM!) < AlternateDraft.minSpanM) {
      return 'The fork and the rejoin are the same point on the route.';
    }
    return null;
  }

  bool get isComplete => blocker == null;

  /// The moved path: the fork, the shaping points in order, and the rejoin,
  /// running from [divergesAtM] to [rejoinsAtM] so a divergence dragged
  /// back-to-front still reads forwards along the day.
  ///
  /// `authored`, never `solved` — the Author drew this line. A re-solve
  /// replaces it with a solved one and stamps [Alternate.solve] to say so.
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

  /// Everything placed, in drawing order — the line the map draws while the
  /// Author is moving handles. Identical to [geometry]'s coordinates once the
  /// edit is complete, so what they are looking at is what gets saved.
  List<Coord> get previewLine =>
      geometry?.coordinates ??
      [
        if (fork != null) fork!.point,
        ...shape,
        if (rejoin != null) rejoin!.point,
      ];

  /// The mark that reads as "leaves here" — the earlier of the two along the
  /// route, or the only one placed.
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

  /// The stretch of the parent passage this alternate stands in for, under the
  /// marks as they are now.
  List<Coord> get canonStretch {
    final from = divergesAtM, to = rejoinsAtM;
    if (from == null || to == null) return const [];
    return pathBetween(route, from, to);
  }

  /// Length of the moved path, in metres — measured off the line, because the
  /// solver has not seen it. Null until the edit is complete.
  double? get alternateDistanceM {
    final g = geometry;
    return g == null ? null : pathLengthM(g.coordinates);
  }

  /// Length of the piece of the day it replaces.
  double? get canonDistanceM {
    final from = divergesAtM, to = rejoinsAtM;
    return (from == null || to == null) ? null : to - from;
  }

  /// Drawn length minus replaced length: negative is shorter than the day as
  /// written, positive is longer.
  double? get deltaM {
    final a = alternateDistanceM, c = canonDistanceM;
    return (a == null || c == null) ? null : a - c;
  }

  /// FR140 / Q3, Flow 11 §06 — does saving this edit make the alternate stale?
  ///
  /// Only when a handle actually moved **and** there was a solve to invalidate.
  /// Both halves matter:
  ///
  ///  * Nothing moved → nothing is invalidated. Opening `Move on the map` and
  ///    closing it again is looking, not editing.
  ///  * Never solved → there is no derived work to go stale. Its distances are
  ///    measured off the line the Author drew and still are after the move;
  ///    every surface already says so ("Measured off the line as drawn, not
  ///    solved"). Marking it stale would put an item in the export gate's list
  ///    that no re-solve was ever owed for, and would make *drawing* an
  ///    alternate — which #324 made the ordinary way to make one — block export.
  ///
  /// That is the same guard `markSegmentStale` applies to a segment with no
  /// `solve`, one level down.
  bool get staleAfterMove => moved && wasSolved;
}
