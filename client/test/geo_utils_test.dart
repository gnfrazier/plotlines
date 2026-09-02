// #235 B6 — `pointAtDistance`, the last zero-coverage file in `client/lib`.
//
// Small, but not incidental: a cue carries `distanceAlongM` and no coordinate
// (see `domain/cue.dart`), so this is the function that decides *where on the
// map* a cue-derived waypoint lands in every export format — GPX, TCX, GeoJSON
// and FIT all call it. An off-by-one-vertex here puts a "turn left" marker at
// the wrong junction on a head unit.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/export/geo_utils.dart';
import 'package:plotlines_client/domain/domain.dart';

/// A straight line east along 40°N in ~100 m steps, so distances are exact
/// enough to assert on directly.
const double _step = 0.001172; // ≈100 m of longitude at 40°N
final List<Coord> _line = [
  for (var i = 0; i < 5; i++) [-105.30 + _step * i, 40.0],
];

void main() {
  test('a distance of zero is the start of the line', () {
    expect(pointAtDistance(_line, 0), _line.first);
  });

  test('a vertex distance lands on that vertex', () {
    final p = pointAtDistance(_line, 200);
    expect(p[0], closeTo(_line[2][0], 1e-5));
    expect(p[1], closeTo(40.0, 1e-9));
  });

  test('a distance between two vertices interpolates', () {
    final p = pointAtDistance(_line, 150);
    expect(p[0], closeTo((_line[1][0] + _line[2][0]) / 2, 1e-5));
  });

  test('past the end it clamps rather than extrapolating', () {
    // A cue whose `distanceAlongM` overshoots — a re-solve that shortened the
    // route, say — must land on the finish, not somewhere off the map.
    expect(pointAtDistance(_line, 99999), _line.last);
  });

  test('a negative distance clamps to the start', () {
    expect(pointAtDistance(_line, -50), _line.first);
  });

  test('a single-vertex line is that vertex, whatever is asked for', () {
    expect(pointAtDistance(const [
      [-105.3, 40.0]
    ], 500), const [-105.3, 40.0]);
  });

  test('an empty line yields the null island rather than throwing', () {
    // Degenerate, but reachable: an export of a passage whose geometry never
    // solved. Returning a point keeps the writer producing a valid file.
    expect(pointAtDistance(const [], 100), const [0, 0]);
  });

  test('a zero-length segment does not divide by zero', () {
    final duplicated = <Coord>[
      [-105.3, 40.0],
      [-105.3, 40.0],
      [-105.3 + _step, 40.0],
    ];

    final p = pointAtDistance(duplicated, 50);

    expect(p[0], closeTo(-105.3 + _step / 2, 1e-5));
  });
}
