// Issue #344, FR20 [AMENDED v2.0] / C4 / FR140 / Q3, Flow 11 §03–§04 and §06 —
// moving an alternate that already exists.
//
// #324 covered drawing one (`alternate_draft_test.dart`). This is its
// counterpart for a path that exists: the Author grabs a handle and puts it
// somewhere else, adds or removes a point along the way, and the result is a
// moved path plus one statement about what that costs — whether the
// alternate's derived half is now stale.
//
// Everything here is pure, which is the point: the rules about what a moved
// handle does are asserted against the value, not fished out of a widget tree.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

/// A straight west→east passage at 40°N. One degree of longitude here is
/// ~85.3 km, so distances along it are large and easy to reason about.
const _route = <Coord>[
  [-105.4, 40.0],
  [-105.0, 40.0],
];

LineString _drawn(List<Coord> coords) =>
    LineString(coordinates: coords, source: 'authored');

/// An alternate leaving the route a quarter of the way along and rejoining
/// three quarters of the way along, bulging north, with one shaping point.
Alternate _alternate({
  SolveProvenance? solve,
  String intent = 'branch',
  String? label = 'Past the Sugarloaf mine',
}) {
  final leaves = <double>[-105.3, 40.0];
  final rejoins = <double>[-105.1, 40.0];
  return Alternate(
    id: 'alt1',
    kind: 'extension',
    intent: intent,
    label: label,
    geometry: _drawn([leaves, const [-105.2, 40.05], rejoins]),
    divergesAtM: haversineM(_route.first, leaves),
    rejoinsAtM: haversineM(_route.first, rejoins),
    solve: solve,
    note: intent == 'branch' ? 'Three miles of old tramway grade.' : null,
  );
}

void main() {
  group('reading an alternate back as an edit', () {
    test('recovers the fork, the rejoin and the shaping points from what was saved', () {
      final edit = AlternateEdit.of(_alternate(), _route);

      expect(edit.alternateId, 'alt1');
      expect(edit.fork!.point, const [-105.3, 40.0]);
      expect(edit.rejoin!.point, const [-105.1, 40.0]);
      expect(edit.shape, const [
        [-105.2, 40.05]
      ]);
      // The marks come back as the distances they were snapped to, not
      // re-derived: `diverges_at_m` is authored, and re-projecting would let
      // it drift by a metre on every open.
      expect(edit.divergesAtM, closeTo(haversineM(_route.first, const [-105.3, 40.0]), 0.001));
      expect(edit.rejoinsAtM, closeTo(haversineM(_route.first, const [-105.1, 40.0]), 0.001));
    });

    test('an alternate drawn before the marks existed opens with them unplaced', () {
      // Not re-derived from the geometry: projecting the endpoints back onto
      // the line would invent a `diverges_at_m` the Author never authored, and
      // placing it is exactly what this surface is for.
      final old = Alternate(
        id: 'alt-old',
        kind: 'bypass',
        geometry: _drawn(const [
          [-105.3, 40.0],
          [-105.1, 40.0],
        ]),
      );
      final edit = AlternateEdit.of(old, _route);

      expect(edit.fork, isNull);
      expect(edit.rejoin, isNull);
      expect(edit.isComplete, isFalse);
      expect(edit.blocker, 'Tap the route where this path leaves it.');
    });

    test('a passage with no solved line has nothing to measure the marks against', () {
      expect(AlternateEdit.canMoveOn(null), isFalse);
      expect(AlternateEdit.canMoveOn(const [
        [-105.4, 40.0]
      ]), isFalse);
      expect(AlternateEdit.canMoveOn(_route), isTrue);
    });

    test('no handle is grabbed to begin with, and a tap does nothing', () {
      final edit = AlternateEdit.of(_alternate(), _route);
      expect(edit.handle, isNull);

      // Panning a map must not silently drag whatever was last selected.
      final tapped = edit.tap(const [-105.25, 40.02]);
      expect(tapped.fork!.point, edit.fork!.point);
      expect(tapped.shape, edit.shape);
      expect(tapped.moved, isFalse);
    });
  });

  group('moving the fork and the rejoin', () {
    test('the fork snaps onto the passage and takes a new distance along it', () {
      final edit = AlternateEdit.of(_alternate(), _route)
          .grab(AlternateHandle.fork)
          // A tap well north of the line: snapped, so `diverges_at_m` is a
          // distance along the day rather than a guess.
          .tap(const [-105.35, 40.03]);

      expect(edit.fork!.point[1], 40.0);
      expect(edit.fork!.point[0], closeTo(-105.35, 1e-9));
      expect(edit.divergesAtM, closeTo(haversineM(_route.first, const [-105.35, 40.0]), 0.5));
      expect(edit.moved, isTrue);
      // The path now starts where the mark does.
      expect(edit.geometry!.coordinates.first[0], closeTo(-105.35, 1e-9));
    });

    test('the rejoin moves independently of the fork', () {
      final start = AlternateEdit.of(_alternate(), _route);
      final edit = start.grab(AlternateHandle.rejoin).tap(const [-105.05, 39.98]);

      expect(edit.fork!.point, start.fork!.point);
      expect(edit.rejoinsAtM, closeTo(haversineM(_route.first, const [-105.05, 40.0]), 0.5));
      expect(edit.geometry!.coordinates.last[0], closeTo(-105.05, 1e-9));
    });

    test('dragging the fork past the rejoin reads forwards, it is not refused', () {
      // The same divergence walked backwards is still that divergence.
      final edit = AlternateEdit.of(_alternate(), _route)
          .grab(AlternateHandle.fork)
          .tap(const [-105.05, 40.0]);

      expect(edit.divergesAtM! < edit.rejoinsAtM!, isTrue);
      expect(edit.leavesPoint, const [-105.1, 40.0]);
      expect(edit.rejoinsPoint![0], closeTo(-105.05, 1e-9));
      // And the geometry runs the same way the day does.
      final coords = edit.geometry!.coordinates;
      expect(coords.first, const [-105.1, 40.0]);
      expect(coords.last[0], closeTo(-105.05, 1e-9));
    });

    test('a fork and a rejoin on the same point is a divergence with nowhere to go', () {
      final edit = AlternateEdit.of(_alternate(), _route)
          .grab(AlternateHandle.fork)
          .tap(const [-105.1, 40.0]);

      expect(edit.isComplete, isFalse);
      expect(edit.blocker, 'The fork and the rejoin are the same point on the route.');
    });

    test('the moved path is authored, never solved', () {
      final edit = AlternateEdit.of(_alternate(), _route)
          .grab(AlternateHandle.fork)
          .tap(const [-105.35, 40.0]);
      // A line the Author drew with a mouse may not wear a solved line's
      // authority — the whole reason #324 tagged the source in the first place.
      expect(edit.geometry!.source, 'authored');
    });
  });

  group('reshaping the path between them', () {
    test('a shaping point moves where it is put, unsnapped', () {
      // Shape points are the drawn path, not a mark on the route: snapping one
      // onto the passage would collapse the bulge the Author drew.
      final edit = AlternateEdit.of(_alternate(), _route)
          .grab(AlternateHandle.shapePoint, index: 0)
          .tap(const [-105.22, 40.09]);

      expect(edit.shape, const [
        [-105.22, 40.09]
      ]);
      expect(edit.geometry!.coordinates[1], const [-105.22, 40.09]);
    });

    test('a new point lands where it was placed, not at the end of the path', () {
      // Appending was the obvious implementation and the wrong one: a point
      // dropped near the fork would otherwise jump past the rejoin and drag
      // the line across the map.
      final edit = AlternateEdit.of(_alternate(), _route)
          .grab(AlternateHandle.newShapePoint)
          .tap(const [-105.28, 40.02]);

      expect(edit.shape, const [
        [-105.28, 40.02],
        [-105.2, 40.05],
      ]);
      // And the point just made is the one in hand, so a placement a little
      // off can be corrected without hunting for it.
      expect(edit.handle, AlternateHandle.shapePoint);
      expect(edit.handleIndex, 0);
    });

    test('a new point near the far end lands after the existing one', () {
      final edit = AlternateEdit.of(_alternate(), _route)
          .grab(AlternateHandle.newShapePoint)
          .tap(const [-105.12, 40.02]);

      expect(edit.shape.last, const [-105.12, 40.02]);
      expect(edit.shape.first, const [-105.2, 40.05]);
    });

    test('removing the grabbed point takes it out of the path and lets go', () {
      final edit = AlternateEdit.of(_alternate(), _route)
          .grab(AlternateHandle.shapePoint, index: 0)
          .removeGrabbedShapePoint();

      expect(edit.shape, isEmpty);
      expect(edit.handle, isNull);
      expect(edit.moved, isTrue);
      // Fork and rejoin alone are still a path — a straight divergence.
      expect(edit.geometry!.coordinates.length, 2);
    });

    test('the fork and the rejoin cannot be removed', () {
      // Removing one is deleting the alternate, which destroys authored work
      // and therefore confirms — a different action, on the card.
      final fork = AlternateEdit.of(_alternate(), _route)
          .grab(AlternateHandle.fork)
          .removeGrabbedShapePoint();
      expect(fork.fork, isNotNull);
      expect(fork.moved, isFalse);

      final nothing =
          AlternateEdit.of(_alternate(), _route).removeGrabbedShapePoint();
      expect(nothing.shape.length, 1);
    });
  });

  group('what the canon stretch and the difference report', () {
    test('the replaced stretch follows the marks as they move', () {
      final edit = AlternateEdit.of(_alternate(), _route)
          .grab(AlternateHandle.fork)
          .tap(const [-105.38, 40.0]);

      // The stretch's ends are interpolated back out of a distance along the
      // line, so they land within a metre rather than on the exact float.
      expect(edit.canonStretch.first[0], closeTo(-105.38, 1e-5));
      expect(edit.canonStretch.last[0], closeTo(-105.1, 1e-5));
      expect(edit.canonDistanceM,
          closeTo(haversineM(const [-105.38, 40.0], const [-105.1, 40.0]), 1.0));
    });

    test('the difference is measured off the moved line, against what it replaces', () {
      final edit = AlternateEdit.of(_alternate(), _route);
      expect(edit.deltaM, edit.alternateDistanceM! - edit.canonDistanceM!);
      // This one bulges north, so it is longer than the stretch it replaces.
      expect(edit.deltaM! > 0, isTrue);
    });
  });

  group('FR140 / Q3 — what a move makes stale', () {
    test('moving a mark on a solved alternate makes it stale', () {
      final edit = AlternateEdit.of(
        _alternate(solve: SolveProvenance(solvedAt: '2026-09-10T15:00:00Z', stale: false)),
        _route,
      ).grab(AlternateHandle.fork).tap(const [-105.35, 40.0]);

      expect(edit.staleAfterMove, isTrue);
    });

    test('opening the gesture and closing it again makes nothing stale', () {
      // Looking is not editing. Staleness is caused by an edit.
      final edit = AlternateEdit.of(
        _alternate(solve: SolveProvenance(stale: false)),
        _route,
      ).grab(AlternateHandle.fork).release();

      expect(edit.moved, isFalse);
      expect(edit.staleAfterMove, isFalse);
    });

    test('moving an alternate that was never solved makes nothing stale', () {
      // There is no derived work to invalidate: its distances are measured off
      // the line the Author drew and still are. Marking it stale would put an
      // item in the export gate's list that no re-solve was ever owed for —
      // and since #324, drawing one is the ordinary way to make one, so every
      // new alternate would block an export.
      final edit = AlternateEdit.of(_alternate(), _route)
          .grab(AlternateHandle.rejoin)
          .tap(const [-105.05, 40.0]);

      expect(edit.wasSolved, isFalse);
      expect(edit.moved, isTrue);
      expect(edit.staleAfterMove, isFalse);
    });

    test('reshaping counts as moving, the same as the two marks', () {
      final edit = AlternateEdit.of(
        _alternate(solve: SolveProvenance(stale: false)),
        _route,
      ).grab(AlternateHandle.shapePoint, index: 0).tap(const [-105.21, 40.08]);

      expect(edit.staleAfterMove, isTrue);
    });
  });
}
