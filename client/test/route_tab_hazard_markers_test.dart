// C11 / FR27 (issue #47) — "highlighted on map": every hazard the trip carries
// gets a hazard mark on the Route tab map, placed from its own point, its
// distance along the passage, its anchor, or its node, in that order. Never
// reveal-gated (FR115).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/route_tab.dart';
import 'package:plotlines_client/presentation/map/hazard_points.dart';

const _line = <Coord>[
  [-105.30, 40.0],
  [-105.20, 40.0],
];

Trip _trip({List<Hazard> segmentHazards = const [], List<Hazard> dayHazards = const [],
        List<Anchor> anchors = const []}) =>
    Trip(
      id: 't1',
      title: 'Trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      anchors: anchors,
      days: [
        Day(
          id: 'd1',
          index: 1,
          hazards: dayHazards,
          segments: [
            Segment(
              id: 's1',
              mode: 'cycling',
              shape: 'point_to_point',
              geometry: LineString(coordinates: _line),
              hazards: segmentHazards,
              nodes: [
                Node(id: 'n1', kind: NodeKind.poi, coord: const [-105.25, 40.01]),
              ],
            ),
          ],
        ),
      ],
    );

List<Coord> _hazardCoords(Trip trip) => [
      for (final p in routeTabMarkerPoints(trip))
        if (p.role == NodeMarkerType.hazard) p.coord,
    ];

void main() {
  test('a hazard with its own point is marked there', () {
    final trip = _trip(segmentHazards: [
      Hazard(id: 'h1', severity: 'high', coord: const [-105.27, 40.0]),
    ]);
    expect(_hazardCoords(trip), [
      [-105.27, 40.0],
    ]);
  });

  test('a hazard with only a distance is placed along its passage line', () {
    final trip = _trip(segmentHazards: [
      Hazard(id: 'h1', severity: 'caution', distanceAlongM: 0),
    ]);
    expect(_hazardCoords(trip), [_line.first]);
  });

  test('a hazard pinned to an anchor or a node stands on it', () {
    final trip = _trip(
      anchors: [
        Anchor(id: 'a1', coord: const [-105.22, 40.02], roles: [
          Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.alwaysVisible, title: 'Ford'),
        ]),
      ],
      segmentHazards: [
        Hazard(id: 'h1', severity: 'high', anchorId: 'a1'),
        Hazard(id: 'h2', severity: 'caution', nodeId: 'n1'),
      ],
    );
    expect(_hazardCoords(trip), [
      [-105.22, 40.02],
      [-105.25, 40.01],
    ]);
  });

  test('a day hazard with nowhere to stand has no mark rather than a guessed one', () {
    final trip = _trip(dayHazards: [Hazard(id: 'h1', severity: 'mandatory_reroute')]);
    expect(_hazardCoords(trip), isEmpty);
  });

  test('the elevation profile marks a hazard at its fraction of the passage', () {
    final trip = _trip(segmentHazards: [
      Hazard(id: 'h1', severity: 'high', distanceAlongM: pathLengthM(_line) / 4),
      Hazard(id: 'h2', severity: 'caution', coord: const [-105.20, 40.0]),
      // Placed well off the line: not on this passage's profile.
      Hazard(id: 'h3', severity: 'caution', coord: const [-105.25, 40.2]),
    ]);
    final segment = trip.days.single.segments.single;
    final fractions = hazardProfileFractions(trip, segment);
    expect(fractions, hasLength(2));
    expect(fractions[0], closeTo(0.25, 0.001));
    expect(fractions[1], closeTo(1.0, 0.001));
  });
}
