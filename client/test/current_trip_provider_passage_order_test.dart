// Story B2 (issue #31), FR11 — assigning passages to a day, reordering them,
// and keeping each junction's measured gap in step with the order.
//
// The point of interest is that resequencing lives in `_replaceDay`, the one
// funnel every day mutation already passes through, so no edit path can leave
// a day's transitions describing an order it no longer has. These tests reach
// it through several different mutations for exactly that reason.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Segment _passage(
  String id, {
  String mode = 'cycling',
  Coord? start,
  Coord? end,
}) =>
    Segment(id: id, mode: mode, shape: 'point_to_point', start: start, end: end);

ProviderContainer _containerWith(List<Segment> segments,
    {List<Transition> transitions = const []}) {
  final container = ProviderContainer();
  container.read(currentTripProvider.notifier).open(
        Trip(
          id: 't1',
          title: 'Test trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          days: [
            Day(
              id: 'day-1',
              index: 1,
              segments: segments,
              transitions: transitions,
            ),
          ],
        ),
      );
  return container;
}

Day _day(ProviderContainer c) => c.read(currentTripProvider).days.single;

void main() {
  group('reorderSegments', () {
    test('reorders the day\'s passages', () {
      final container = _containerWith([_passage('a'), _passage('b'), _passage('c')]);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).reorderSegments('day-1', 0, 3);

      expect(_day(container).segments.map((s) => s.id), ['b', 'c', 'a']);
    });

    test('rebuilds the transitions to match the new order', () {
      final container = _containerWith([_passage('a'), _passage('b'), _passage('c')]);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).reorderSegments('day-1', 2, 0);

      final transitions = _day(container).transitions;
      expect(transitions.map((t) => '${t.fromSegmentId}>${t.toSegmentId}'), ['c>a', 'a>b']);
    });

    test('re-measures the gap, so a reorder that closes a hole clears the warning', () {
      // `a` ends where `c` starts; `b` is 850 m away. Ordered a-b-c both
      // junctions are gaps; ordered a-c-b only the second one is.
      final container = _containerWith([
        _passage('a', start: const [-105.30, 40.00], end: const [-105.30, 40.00]),
        _passage('b', start: const [-105.29, 40.00], end: const [-105.29, 40.00]),
        _passage('c', start: const [-105.30, 40.00], end: const [-105.30, 40.00]),
      ]);
      addTearDown(container.dispose);

      expect(gapWarnings(_day(container)).length, 2);

      container.read(currentTripProvider.notifier).reorderSegments('day-1', 2, 1);

      expect(_day(container).segments.map((s) => s.id), ['a', 'c', 'b']);
      final warnings = gapWarnings(_day(container));
      expect(warnings.length, 1);
      expect(warnings.single.fromSegmentId, 'c');
    });
  });

  group('movePassage', () {
    test('moves a passage one place later', () {
      final container = _containerWith([_passage('a'), _passage('b'), _passage('c')]);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).movePassage('day-1', 'a', by: 1);

      expect(_day(container).segments.map((s) => s.id), ['b', 'a', 'c']);
    });

    test('moves a passage one place earlier', () {
      final container = _containerWith([_passage('a'), _passage('b'), _passage('c')]);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).movePassage('day-1', 'c', by: -1);

      expect(_day(container).segments.map((s) => s.id), ['a', 'c', 'b']);
    });

    test('is a no-op at either end of the day, and for a passage not in it', () {
      final container = _containerWith([_passage('a'), _passage('b')]);
      addTearDown(container.dispose);
      final notifier = container.read(currentTripProvider.notifier);

      notifier.movePassage('day-1', 'a', by: -1);
      notifier.movePassage('day-1', 'b', by: 1);
      notifier.movePassage('day-1', 'nope', by: 1);

      expect(_day(container).segments.map((s) => s.id), ['a', 'b']);
    });
  });

  group('transitions stay in step with every other day mutation', () {
    test('removing a passage rebuilds the junctions around the hole it leaves', () {
      final container = _containerWith([_passage('a'), _passage('b'), _passage('c')]);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).removeSegment('day-1', 'b');

      expect(_day(container).transitions.map((t) => '${t.fromSegmentId}>${t.toSegmentId}'),
          ['a>c']);
    });

    test('moving an endpoint re-measures the junction it belongs to', () {
      final container = _containerWith([
        _passage('a', start: const [-105.30, 40.00], end: const [-105.30, 40.00]),
        _passage('b', start: const [-105.30, 40.00], end: const [-105.25, 40.00]),
      ]);
      addTearDown(container.dispose);
      expect(_day(container).transitions.single.gapWarning, isFalse);

      container
          .read(currentTripProvider.notifier)
          .updateSegmentEndpoints('day-1', 'a', end: const [-105.29, 40.00]);

      final t = _day(container).transitions.single;
      expect(t.gapWarning, isTrue);
      expect(t.gapM, closeTo(852.0, 5.0));
    });

    test('a day with one passage holds no transition at all', () {
      final container = _containerWith([_passage('a'), _passage('b')]);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).removeSegment('day-1', 'b');

      expect(_day(container).transitions, isEmpty);
    });

    test('B3 Author instructions survive a reorder that keeps the pair adjacent', () {
      final container = _containerWith([
        _passage('a'),
        _passage('b'),
        _passage('c'),
      ], transitions: [
        Transition(
          id: 'tab',
          fromSegmentId: 'a',
          toSegmentId: 'b',
          node: Node(
            id: 'n1',
            kind: NodeKind.transition,
            coord: const [-105.30, 40.00],
            instructions: 'Take out river left, above the weir.',
          ),
        ),
      ]);
      addTearDown(container.dispose);

      // Move `c` to the front — `a` → `b` is still a junction.
      container.read(currentTripProvider.notifier).movePassage('day-1', 'c', by: -2);

      expect(_day(container).segments.map((s) => s.id), ['c', 'a', 'b']);
      final t = _day(container).transitions.firstWhere((t) => t.toSegmentId == 'b');
      expect(t.id, 'tab');
      expect(t.node?.instructions, 'Take out river left, above the weir.');
    });
  });

  group('a passage is assignable to a day', () {
    test('a second day keeps its own sequence, untouched by the first', () {
      final container = _containerWith([_passage('a'), _passage('b')]);
      addTearDown(container.dispose);
      final notifier = container.read(currentTripProvider.notifier);
      final secondDayId = notifier.addBlankDay();

      notifier.reorderSegments('day-1', 0, 2);

      final trip = container.read(currentTripProvider);
      expect(trip.days.firstWhere((d) => d.id == secondDayId).transitions, isEmpty);
      expect(trip.days.first.transitions.single.fromSegmentId, 'b');
    });
  });
}
