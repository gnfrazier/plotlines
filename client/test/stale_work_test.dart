// Story Q3 (issue #123), FR140/FR140a — the pure stale-list mechanics: which
// segments are stale, named by what they are and which day they're on, and
// the trip-wide export/print gate ("a stale route stays viewable but is not
// exportable or printable").
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  Segment segment(String id, {bool stale = false}) => Segment(
        id: id,
        mode: 'cycling',
        shape: 'loop',
        solve: stale ? SolveProvenance(stale: true) : SolveProvenance(stale: false),
      );

  test('a trip with no segments has no stale items and is ready to export', () {
    final trip = Trip(
      id: 't1',
      title: 'Trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
    );
    expect(tripStaleItems(trip), isEmpty);
    expect(tripStaleCount(trip), 0);
    expect(tripReadyToExport(trip), isTrue);
  });

  test('a segment with no solve at all is not stale (nothing to go stale yet)', () {
    final day = Day(id: 'd1', index: 1, segments: [Segment(id: 's1', mode: 'cycling', shape: 'loop')]);
    final trip = Trip(
      id: 't1',
      title: 'Trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [day],
    );
    expect(tripStaleItems(trip), isEmpty);
    expect(tripReadyToExport(trip), isTrue);
  });

  test('finds every stale segment across every day, named by day and what it is', () {
    final day1 = Day(id: 'd1', index: 1, segments: [segment('s1', stale: true), segment('s2')]);
    final day2 = Day(id: 'd2', index: 2, segments: [segment('s3', stale: true)]);
    final trip = Trip(
      id: 't1',
      title: 'Trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [day1, day2],
    );

    final items = tripStaleItems(trip);
    expect(items.map((i) => i.segmentId), ['s1', 's3']);
    expect(items[0].dayId, 'd1');
    expect(items[0].dayIndex, 1);
    expect(items[1].dayId, 'd2');
    expect(items[1].dayIndex, 2);
    expect(items[0].label, contains('Day 1'));
    expect(tripStaleCount(trip), 2);
    expect(tripReadyToExport(trip), isFalse);
  });
}
