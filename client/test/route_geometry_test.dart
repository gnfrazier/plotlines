// #322 — `nearestPointOnPath`: where on a route line a node's closest point
// sits, and how far off the line it is. Used to draw the leader line on the
// Route tab and to gate the node editor's "Snap to route" affordance.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/map/route_geometry.dart';

void main() {
  group('nearestPointOnPath', () {
    test('a line of fewer than two vertices has nothing to measure against', () {
      expect(nearestPointOnPath(const [], const [-105.0, 40.0]), isNull);
      expect(
        nearestPointOnPath(const [
          [-105.0, 40.0]
        ], const [-105.0, 40.0]),
        isNull,
      );
    });

    test('a point on the line reports ~zero offset', () {
      final path = <Coord>[
        [-105.0, 40.0],
        [-105.0, 40.01],
      ];
      final near = nearestPointOnPath(path, const [-105.0, 40.005])!;
      expect(near.distanceM, lessThan(1.0));
      expect(near.point[0], closeTo(-105.0, 1e-6));
      expect(near.point[1], closeTo(40.005, 1e-6));
    });

    test('a point off a segment projects onto its perpendicular foot', () {
      // A west–east segment at latitude 40°. The query point sits due north
      // of its midpoint; 0.001° of latitude is ~111 m.
      final path = <Coord>[
        [-105.010, 40.0],
        [-105.000, 40.0],
      ];
      final near = nearestPointOnPath(path, const [-105.005, 40.001])!;
      expect(near.point[0], closeTo(-105.005, 1e-4));
      expect(near.point[1], closeTo(40.0, 1e-4));
      expect(near.distanceM, closeTo(111.2, 3.0));
    });

    test('the foot is clamped to the segment — a point past the end snaps to '
        'the vertex, not the infinite line', () {
      final path = <Coord>[
        [-105.010, 40.0],
        [-105.000, 40.0],
      ];
      // Well east of the eastern vertex.
      final near = nearestPointOnPath(path, const [-104.990, 40.0])!;
      expect(near.point[0], closeTo(-105.000, 1e-6));
      expect(near.point[1], closeTo(40.0, 1e-6));
      expect(near.distanceM, greaterThan(500));
    });

    test('picks the closest segment of a multi-vertex path', () {
      final path = <Coord>[
        [-105.02, 40.00],
        [-105.02, 40.02],
        [-105.00, 40.02],
      ];
      // Just east of the vertical first leg.
      final near = nearestPointOnPath(path, const [-105.019, 40.01])!;
      expect(near.point[0], closeTo(-105.02, 1e-4));
      expect(near.point[1], closeTo(40.01, 1e-4));
      expect(near.distanceM, lessThan(120));
    });
  });
}
