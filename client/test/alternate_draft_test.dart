// Issue #324, FR20 [AMENDED v2.0] / C4 — the map gesture that makes an
// alternate. Creating one used to open a card on a path that did not exist
// (`EXTENSION · not drawn`) and ask the Author to name, shape, describe and set
// the reveal of it; the order inverts, and this is the half that decides what
// a drawable divergence is.
//
// The route used throughout is a straight east–west line at 40°N, so distances
// along it are easy to reason about: one degree of longitude there is about
// 85.4 km, and the assertions use tolerances rather than exact metres because
// the measurement is a real haversine, not a planar approximation.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/domain.dart';

/// A straight line west→east at 40°N, five vertices, 0.4° wide.
const _route = <Coord>[
  [-105.4, 40.0],
  [-105.3, 40.0],
  [-105.2, 40.0],
  [-105.1, 40.0],
  [-105.0, 40.0],
];

double get _routeM => pathLengthM(_route);

void main() {
  group('snapToPath', () {
    test('returns the foot of the perpendicular, its offset, and its distance along', () {
      // A tap 0.01° north of the line, a quarter of the way along it.
      final snap = snapToPath(_route, const [-105.3, 40.01]);
      expect(snap, isNotNull);
      expect(snap!.point[0], closeTo(-105.3, 1e-6));
      expect(snap.point[1], closeTo(40.0, 1e-6));
      // 0.01° of latitude is ~1111 m, and that is the off-line distance.
      expect(snap.offsetM, closeTo(1111, 20));
      expect(snap.alongM, closeTo(_routeM * 0.25, 50));
    });

    test('clamps to the ends rather than extrapolating past them', () {
      final before = snapToPath(_route, const [-105.9, 40.0])!;
      expect(before.alongM, closeTo(0, 1));
      final after = snapToPath(_route, const [-104.5, 40.0])!;
      expect(after.alongM, closeTo(_routeM, 1));
    });

    test('a path with fewer than two vertices has nothing to measure against', () {
      expect(snapToPath(const [], const [-105.2, 40.0]), isNull);
      expect(snapToPath(const [[-105.2, 40.0]], const [-105.2, 40.0]), isNull);
    });
  });

  group('pathBetween', () {
    test('keeps the vertices inside the span and interpolates both ends', () {
      final stretch = pathBetween(_route, _routeM * 0.25, _routeM * 0.75);
      expect(stretch.first[0], closeTo(-105.3, 1e-4));
      expect(stretch.last[0], closeTo(-105.1, 1e-4));
      // The one interior vertex of the route inside that span.
      expect(stretch.length, 3);
      expect(stretch[1][0], closeTo(-105.2, 1e-9));
    });

    test('reads the same span given its ends in either order', () {
      final forward = pathBetween(_route, 1000, 5000);
      final backward = pathBetween(_route, 5000, 1000);
      expect(backward, forward);
    });
  });

  group('AlternateDraft — the gesture', () {
    test('a passage with no solved line cannot be diverged from', () {
      expect(AlternateDraft.canDraftOn(null), isFalse);
      expect(AlternateDraft.canDraftOn(const [[-105.2, 40.0]]), isFalse);
      expect(AlternateDraft.canDraftOn(_route), isTrue);
    });

    test('asks for the fork, then the rejoin, then shape', () {
      var draft = AlternateDraft.on(_route);
      expect(draft.stage, AlternateDraftStage.fork);
      expect(draft.blocker, 'Tap the route where this path leaves it.');

      draft = draft.tap(const [-105.3, 40.01]);
      expect(draft.stage, AlternateDraftStage.rejoin);
      expect(draft.blocker, 'Tap the route where this path comes back.');

      draft = draft.tap(const [-105.1, 40.01]);
      expect(draft.stage, AlternateDraftStage.shape);
      expect(draft.blocker, isNull);
      expect(draft.isComplete, isTrue);
    });

    test('fork and rejoin snap onto the route; shape points are kept where they land', () {
      final draft = AlternateDraft.on(_route)
          .tap(const [-105.3, 40.02]) // fork, off the line
          .tap(const [-105.1, 40.02]) // rejoin, off the line
          .tap(const [-105.2, 40.05]); // shape, well off the line

      expect(draft.fork!.point[1], closeTo(40.0, 1e-9), reason: 'fork snapped to the route');
      expect(draft.rejoin!.point[1], closeTo(40.0, 1e-9), reason: 'rejoin snapped to the route');
      expect(draft.shape.single, const [-105.2, 40.05], reason: 'the drawn path is not snapped');
    });

    test('the geometry is the fork, the shaping points in order, and the rejoin', () {
      final draft = AlternateDraft.on(_route)
          .tap(const [-105.3, 40.0])
          .tap(const [-105.1, 40.0])
          .tap(const [-105.25, 40.05])
          .tap(const [-105.15, 40.05]);

      final g = draft.geometry!;
      expect(g.source, 'authored', reason: 'the Author drew this, the engine did not solve it');
      expect(g.coordinates.length, 4);
      expect(g.coordinates.first[0], closeTo(-105.3, 1e-6));
      expect(g.coordinates[1], const [-105.25, 40.05]);
      expect(g.coordinates[2], const [-105.15, 40.05]);
      expect(g.coordinates.last[0], closeTo(-105.1, 1e-6));
      // `$defs/line_string` requires two coordinates — the reason `not drawn`
      // was never a valid payload in the first place.
      expect(g.coordinates.length, greaterThanOrEqualTo(2));
    });

    test('a divergence marked back-to-front is ordered, not refused', () {
      // Rejoin tapped first (further along), fork second.
      final draft = AlternateDraft.on(_route)
          .tap(const [-105.1, 40.0])
          .tap(const [-105.3, 40.0])
          .tap(const [-105.2, 40.05]);

      expect(draft.divergesAtM! < draft.rejoinsAtM!, isTrue);
      expect(draft.divergesAtM, closeTo(_routeM * 0.25, 50));
      expect(draft.rejoinsAtM, closeTo(_routeM * 0.75, 50));
      // Geometry and the two marks all read forwards along the day.
      expect(draft.geometry!.coordinates.first[0], closeTo(-105.3, 1e-6));
      expect(draft.geometry!.coordinates.last[0], closeTo(-105.1, 1e-6));
      expect(draft.leavesPoint![0], closeTo(-105.3, 1e-6));
      expect(draft.rejoinsPoint![0], closeTo(-105.1, 1e-6));
    });

    test('a fork and rejoin on the same point is a divergence with nowhere to go', () {
      final draft = AlternateDraft.on(_route)
          .tap(const [-105.2, 40.0])
          .tap(const [-105.2, 40.0]);
      expect(draft.isComplete, isFalse);
      expect(draft.blocker, 'The fork and the rejoin are the same point on the route.');
      expect(draft.geometry, isNull);
    });

    test('undo takes back the last placement, in reverse order', () {
      var draft = AlternateDraft.on(_route)
          .tap(const [-105.3, 40.0])
          .tap(const [-105.1, 40.0])
          .tap(const [-105.2, 40.05]);

      draft = draft.undoLast();
      expect(draft.shape, isEmpty);
      expect(draft.stage, AlternateDraftStage.shape);

      draft = draft.undoLast();
      expect(draft.rejoin, isNull);
      expect(draft.stage, AlternateDraftStage.rejoin);

      draft = draft.undoLast();
      expect(draft.fork, isNull);
      expect(draft.stage, AlternateDraftStage.fork);

      // Nothing left to take back.
      expect(draft.undoLast().fork, isNull);
    });

    test('a straight divergence measures shorter than the stretch it replaces only when it is', () {
      // Fork and rejoin with nothing between them: the drawn line runs along
      // the route itself, so the difference is ~zero and the shape reads as an
      // extension only because it is not shorter.
      final flat = AlternateDraft.on(_route)
          .tap(const [-105.3, 40.0])
          .tap(const [-105.1, 40.0]);
      expect(flat.canonDistanceM, closeTo(_routeM * 0.5, 50));
      expect(flat.deltaM!.abs(), lessThan(50));

      // A detour north adds real distance.
      final detour = flat.tap(const [-105.2, 40.1]);
      expect(detour.deltaM, greaterThan(1000));
      expect(detour.impliedKind, 'extension');
    });

    test('a path that cuts a corner off the route is a bypass', () {
      // A route with a northward dogleg, and an alternate straight across it.
      const dogleg = <Coord>[
        [-105.3, 40.0],
        [-105.2, 40.1],
        [-105.1, 40.0],
      ];
      final draft = AlternateDraft.on(dogleg)
          .tap(const [-105.3, 40.0])
          .tap(const [-105.1, 40.0]);
      expect(draft.deltaM, lessThan(0));
      expect(draft.impliedKind, 'bypass');
    });

    test('the replaced stretch is the piece of the day between the two marks', () {
      final draft = AlternateDraft.on(_route)
          .tap(const [-105.3, 40.0])
          .tap(const [-105.1, 40.0]);
      final stretch = draft.canonStretch;
      expect(stretch.first[0], closeTo(-105.3, 1e-4));
      expect(stretch.last[0], closeTo(-105.1, 1e-4));
      expect(pathLengthM(stretch), closeTo(draft.canonDistanceM!, 5));
    });

    test('the preview line is what is placed so far, and becomes the geometry', () {
      var draft = AlternateDraft.on(_route);
      expect(draft.previewLine, isEmpty);

      draft = draft.tap(const [-105.3, 40.0]);
      expect(draft.previewLine.length, 1, reason: 'a fork alone is still a mark, not a path');

      draft = draft.tap(const [-105.1, 40.0]);
      expect(draft.previewLine, draft.geometry!.coordinates);
    });
  });

  group('AlternateGeometryReadout — the same numbers, read off a saved alternate', () {
    Alternate saved({double? distanceM}) => Alternate(
          id: 'a1',
          kind: 'extension',
          divergesAtM: 1000.0,
          rejoinsAtM: 5000.0,
          metrics: distanceM == null ? null : RouteMetrics(distanceM: distanceM),
          geometry: LineString(
            coordinates: const [
              [-105.3, 40.0],
              [-105.2, 40.05],
              [-105.1, 40.0],
            ],
            source: 'authored',
          ),
        );

    test('an unsolved alternate is measured off the line it was drawn as', () {
      final a = saved();
      expect(a.hasForkAndRejoin, isTrue);
      expect(a.canonSpanM, 4000.0);
      expect(a.drawnDistanceM, closeTo(pathLengthM(a.geometry.coordinates), 1e-9));
      expect(a.distanceDeltaM, closeTo(a.drawnDistanceM - 4000.0, 1e-9));
    });

    test('a solved alternate uses the engine\'s distance, not the drawn one', () {
      final a = saved(distanceM: 9000.0);
      expect(a.drawnDistanceM, 9000.0);
      expect(a.distanceDeltaM, 5000.0);
    });

    test('an alternate with no marks reports no span rather than guessing one', () {
      final a = Alternate(
        id: 'a2',
        kind: 'bypass',
        geometry: LineString(coordinates: const [
          [-105.3, 40.0],
          [-105.1, 40.0],
        ], source: 'authored'),
      );
      expect(a.hasForkAndRejoin, isFalse);
      expect(a.canonSpanM, isNull);
      expect(a.distanceDeltaM, isNull);
    });
  });

  group('the model refuses an undrawn alternate', () {
    test('an alternate with an empty line-string cannot be constructed', () {
      expect(
        () => Alternate(
          id: 'x',
          kind: 'bypass',
          geometry: LineString(coordinates: const [], source: 'authored'),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
