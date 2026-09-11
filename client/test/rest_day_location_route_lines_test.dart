// Issue #325 — `routeLinesOf`, the "finished route" the offline buffer
// wraps around: every solved segment's geometry across the whole trip.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/rest_day_location_screen.dart';

Trip _tripWith(List<Day> days) => Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: days,
    );

void main() {
  test('collects every solved segment across every day', () {
    final trip = _tripWith([
      Day(id: 'd1', index: 1, segments: [
        Segment(
          id: 's1', mode: 'cycling', shape: 'point_to_point', start: const [0, 0],
          geometry: LineString(coordinates: const [
            [0, 0],
            [1, 1],
          ]),
        ),
      ]),
      Day(id: 'd2', index: 2, segments: [
        Segment(
          id: 's2', mode: 'hiking', shape: 'point_to_point', start: const [2, 2],
          geometry: LineString(coordinates: const [
            [2, 2],
            [3, 3],
          ]),
        ),
      ]),
    ]);

    final lines = routeLinesOf(trip);
    expect(lines, hasLength(2));
    expect(lines[0], const [
      [0, 0],
      [1, 1],
    ]);
    expect(lines[1], const [
      [2, 2],
      [3, 3],
    ]);
  });

  test('an unsolved segment (no geometry yet) contributes nothing', () {
    final trip = _tripWith([
      Day(id: 'd1', index: 1, segments: [
        Segment(id: 's1', mode: 'cycling', shape: 'point_to_point', start: const [0, 0]),
      ]),
    ]);

    expect(routeLinesOf(trip), isEmpty);
  });

  test('a rest day (no segments) contributes nothing', () {
    final trip = _tripWith([
      Day(id: 'd1', index: 1, kind: 'rest', location: const [0, 0]),
    ]);

    expect(routeLinesOf(trip), isEmpty);
  });

  test('a brand-new trip with no days at all is an empty list, not an error', () {
    expect(routeLinesOf(_tripWith(const [])), isEmpty);
  });
}
