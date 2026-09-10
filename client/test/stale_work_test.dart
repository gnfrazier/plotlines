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
    expect(items[0].isAlternate, isFalse);
    expect(tripStaleCount(trip), 2);
    expect(tripReadyToExport(trip), isFalse);
  });

  // Issue #344 — an alternate carries its own `solve`, so it goes stale on its
  // own: moving where it forks or rejoins invalidates *its* distances while
  // the passage it hangs off stays exactly as solved.
  group('a stale alternate is an item in its own right', () {
    LineString drawn() => LineString(
          coordinates: const [
            [-105.3, 40.0],
            [-105.1, 40.0],
          ],
          source: 'authored',
        );

    Alternate alternate(String id, {bool? stale, String? label, bool branch = false}) =>
        Alternate(
          id: id,
          kind: 'extension',
          intent: branch ? 'branch' : 'accommodation',
          label: label,
          geometry: drawn(),
          solve: stale == null ? null : SolveProvenance(stale: stale),
        );

    Trip tripWith(Segment segment) => Trip(
          id: 't1',
          title: 'Trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          days: [Day(id: 'd1', index: 1, segments: [segment])],
        );

    test('names the branch and the day, and points back at its own passage', () {
      final trip = tripWith(Segment(
        id: 's1',
        mode: 'cycling',
        shape: 'loop',
        solve: SolveProvenance(stale: false),
        alternates: [
          alternate('a1', stale: true, label: 'Past the Sugarloaf mine', branch: true)
        ],
      ));

      final items = tripStaleItems(trip);
      expect(items, hasLength(1));
      expect(items.single.isAlternate, isTrue);
      expect(items.single.alternateId, 'a1');
      expect(items.single.alternateIsBranch, isTrue);
      // The segment id is the passage the branch hangs off, which is what a
      // re-solve needs to find it again — not a claim that the passage itself
      // is stale.
      expect(items.single.segmentId, 's1');
      expect(items.single.label, contains('Day 1'));
      expect(items.single.label, contains('branch'));
      expect(items.single.label, contains('Past the Sugarloaf mine'));
      expect(tripReadyToExport(trip), isFalse);
    });

    test('an unnamed accommodation still says which kind it is', () {
      final trip = tripWith(Segment(
        id: 's1',
        mode: 'cycling',
        shape: 'loop',
        alternates: [alternate('a1', stale: true)],
      ));

      final label = tripStaleItems(trip).single.label;
      expect(label, contains('alternate'));
      expect(label, isNot(contains('branch')));
    });

    test('an alternate that was never solved is not stale and blocks nothing', () {
      // Its distances are measured off the line the Author drew and say so.
      // There is no derived work to invalidate — and since #324 made drawing
      // one the ordinary way to create one, the opposite reading would make
      // every new alternate block an export.
      final trip = tripWith(Segment(
        id: 's1',
        mode: 'cycling',
        shape: 'loop',
        alternates: [alternate('a1'), alternate('a2', stale: false)],
      ));

      expect(tripStaleItems(trip), isEmpty);
      expect(tripReadyToExport(trip), isTrue);
    });

    test('a stale passage is listed before the alternates hanging off it', () {
      // Re-solve-all walks this order, so the day's line is re-solved first
      // and the branch is then measured against the route it will leave.
      final trip = tripWith(Segment(
        id: 's1',
        mode: 'cycling',
        shape: 'loop',
        solve: SolveProvenance(stale: true),
        alternates: [alternate('a1', stale: true)],
      ));

      final items = tripStaleItems(trip);
      expect(items.map((i) => i.alternateId), [null, 'a1']);
      expect(tripStaleCount(trip), 2);
    });
  });
}
