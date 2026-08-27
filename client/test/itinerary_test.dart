// F2 (FR48, FR133) — `buildItinerary`'s AC coverage:
//   - master aggregates every day (modes/distance/places/rest days)
//   - an individual itinerary reflects only the attended days' passages
//   - a day's account is prose, never a table (FR133 — the Frodo principle)
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

Segment _passage(
  String id, {
  required String mode,
  double distanceM = 12000,
  List<Node> nodes = const [],
  List<Hazard> hazards = const [],
}) =>
    Segment(
      id: id,
      mode: mode,
      shape: 'point_to_point',
      metrics: RouteMetrics(distanceM: distanceM),
      nodes: nodes,
      hazards: hazards,
    );

Trip _trip(List<Day> days) => Trip(
      id: 't1',
      title: 'Blue Ridge Traverse',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: days,
    );

void main() {
  group('buildItinerary — master', () {
    test('aggregates every day, in order, with mode + distance prose', () {
      final trip = _trip([
        Day(id: 'd1', index: 1, title: 'To the Gap', segments: [
          _passage('s1', mode: 'cycling', distanceM: 42000),
        ]),
        Day(id: 'd2', index: 2, kind: 'rest', location: [-82.5, 35.6], note: 'Camp at the shelter.'),
      ]);

      final itinerary = buildItinerary(trip);

      expect(itinerary.isIndividual, isFalse);
      expect(itinerary.title, 'Blue Ridge Traverse');
      expect(itinerary.days, hasLength(2));

      final day1 = itinerary.days[0];
      expect(day1.heading, 'Day 1 — To the Gap');
      expect(day1.paragraphs.single, 'Ride (42.0 km).');

      final day2 = itinerary.days[1];
      expect(day2.heading, 'Day 2');
      expect(day2.paragraphs.single, 'Camp at the shelter.');
    });

    test('weaves places, hazards, and portages into the day\'s prose, not a separate table', () {
      final trip = _trip([
        Day(id: 'd1', index: 1, segments: [
          _passage(
            's1',
            mode: 'paddling',
            distanceM: 8000,
            nodes: [
              Node(id: 'n1', kind: NodeKind.restStop, coord: const [0, 0], title: 'Sam\'s Gap spring'),
            ],
            hazards: [
              Hazard(id: 'h1', severity: 'high', title: 'Class III rapid'),
            ],
          ),
        ]),
      ]);

      final itinerary = buildItinerary(trip);
      final paragraphs = itinerary.days.single.paragraphs;

      expect(paragraphs, contains('Along the way: Sam\'s Gap spring.'));
      expect(paragraphs, contains('Watch for Class III rapid.'));
      // Exactly one heading + N narrative paragraphs — no separate cue/logistics table structure.
      expect(paragraphs.every((p) => !p.contains('|')), isTrue);
    });

    test('a mode change between passages reads as a switch, in one flowing sentence', () {
      // `dayTimeline` (which `buildItinerary` reads) only surfaces a mode
      // change when the day carries an explicit `Transition` for that
      // junction — `resequencePassages` (`passage_sequence.dart`) is the
      // established way to build one from adjacent segment modes, the same
      // way `CurrentTripNotifier` does on every real day mutation.
      final trip = _trip([
        resequencePassages(Day(id: 'd1', index: 1, segments: [
          _passage('s1', mode: 'cycling', distanceM: 20000),
          _passage('s2', mode: 'hiking', distanceM: 5000),
        ])),
      ]);

      final itinerary = buildItinerary(trip);
      expect(itinerary.days.single.paragraphs.single,
          'Ride (20.0 km), then switch to Hike, then Hike (5.0 km).');
    });
  });

  group('buildItinerary — individual', () {
    test('reflects only the attended days, dropping the rest entirely', () {
      final trip = _trip([
        Day(id: 'd1', index: 1, segments: [_passage('s1', mode: 'cycling')]),
        Day(id: 'd2', index: 2, segments: [_passage('s2', mode: 'hiking')]),
        Day(id: 'd3', index: 3, segments: [_passage('s3', mode: 'paddling')]),
      ]);

      final itinerary = buildItinerary(trip, attendedDayIds: {'d1', 'd3'});

      expect(itinerary.isIndividual, isTrue);
      expect(itinerary.days.map((e) => e.day.id).toList(), ['d1', 'd3']);
    });

    test('carries a Character label into the title when given', () {
      final trip = _trip([Day(id: 'd1', index: 1)]);
      final itinerary =
          buildItinerary(trip, attendedDayIds: {'d1'}, characterLabel: 'Sam');
      expect(itinerary.title, 'Blue Ridge Traverse — Sam');
    });

    test('an empty attendance set produces an itinerary with no days, not the master', () {
      final trip = _trip([Day(id: 'd1', index: 1)]);
      final itinerary = buildItinerary(trip, attendedDayIds: {});
      expect(itinerary.isIndividual, isTrue);
      expect(itinerary.days, isEmpty);
    });
  });
}
