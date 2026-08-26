// Story Q1 (issue #121), FR139 — day count is editable at any time: days
// insert mid-trip (not just append) with subsequent days renumbering and
// their content moving with them; reducing the count drops empty trailing
// days with no prompt but leaves non-empty ones for the Author to resolve
// via merge-into-adjacent or explicit removal — this file exercises the
// `CurrentTripNotifier` methods a caller's day-count-reduction prompt sits
// in front of.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

void main() {
  ProviderContainer containerWithDays(List<Day> days) {
    final container = ProviderContainer();
    container.read(currentTripProvider.notifier).open(
          Trip(
            id: 't1',
            title: 'Test trip',
            createdAt: '2026-01-01T00:00:00Z',
            updatedAt: '2026-01-01T00:00:00Z',
            days: days,
          ),
        );
    return container;
  }

  Segment segmentWithNode(String id) => Segment(
        id: id,
        mode: 'cycling',
        shape: 'loop',
        nodes: [Node(id: '$id-node', kind: NodeKind.poi, coord: const [0, 0])],
      );

  group('insertDayAt', () {
    test('inserting mid-trip renumbers subsequent days and moves their content along', () {
      final container = containerWithDays([
        Day(id: 'd1', index: 1, segments: [segmentWithNode('s1')]),
        Day(id: 'd2', index: 2, segments: [segmentWithNode('s2')]),
      ]);
      addTearDown(container.dispose);

      final newId = container.read(currentTripProvider.notifier).insertDayAt(2);

      final trip = container.read(currentTripProvider);
      final byIndex = {for (final d in trip.days) d.index: d};
      expect(trip.days, hasLength(3));
      expect(byIndex[1]!.id, 'd1');
      expect(byIndex[2]!.id, newId);
      expect(byIndex[2]!.segments, isEmpty);
      // Day 2's original content ("d2") moved with it to index 3.
      expect(byIndex[3]!.id, 'd2');
      expect(byIndex[3]!.segments.single.id, 's2');
    });

    test('inserting at the end appends without disturbing earlier days', () {
      final container = containerWithDays([Day(id: 'd1', index: 1)]);
      addTearDown(container.dispose);

      final newId = container.read(currentTripProvider.notifier).insertDayAt(2);

      final trip = container.read(currentTripProvider);
      expect(trip.days.map((d) => d.index).toList(), [1, 2]);
      expect(trip.days.firstWhere((d) => d.index == 2).id, newId);
    });

    test('a position beyond the trip length clamps to an append', () {
      final container = containerWithDays([Day(id: 'd1', index: 1)]);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).insertDayAt(99);

      final trip = container.read(currentTripProvider);
      expect(trip.days.map((d) => d.index).toList(), [1, 2]);
    });
  });

  group('reduceDayCount', () {
    test('empty trailing days are removed with no prompt and no leftover', () {
      final container = containerWithDays([
        Day(id: 'd1', index: 1, segments: [segmentWithNode('s1')]),
        Day(id: 'd2', index: 2),
        Day(id: 'd3', index: 3),
      ]);
      addTearDown(container.dispose);

      final needsResolution =
          container.read(currentTripProvider.notifier).reduceDayCount(1);

      expect(needsResolution, isEmpty);
      final trip = container.read(currentTripProvider);
      expect(trip.days, hasLength(1));
      expect(trip.days.single.id, 'd1');
    });

    test('non-empty trailing days are left untouched and reported for the Author to resolve', () {
      final container = containerWithDays([
        Day(id: 'd1', index: 1),
        Day(id: 'd2', index: 2, segments: [segmentWithNode('s2')]),
        Day(id: 'd3', index: 3, segments: [segmentWithNode('s3')]),
      ]);
      addTearDown(container.dispose);

      final needsResolution =
          container.read(currentTripProvider.notifier).reduceDayCount(1);

      // Nothing removed yet — both non-empty days are still there.
      expect(container.read(currentTripProvider).days, hasLength(3));
      expect(needsResolution.map((d) => d.id).toSet(), {'d2', 'd3'});
    });

    test('a mix of empty and non-empty trailing days only auto-removes the empty ones', () {
      final container = containerWithDays([
        Day(id: 'd1', index: 1),
        Day(id: 'd2', index: 2, segments: [segmentWithNode('s2')]),
        Day(id: 'd3', index: 3), // empty
      ]);
      addTearDown(container.dispose);

      final needsResolution =
          container.read(currentTripProvider.notifier).reduceDayCount(1);

      expect(needsResolution.map((d) => d.id).toList(), ['d2']);
      final trip = container.read(currentTripProvider);
      expect(trip.days.map((d) => d.id).toSet(), {'d1', 'd2'});
    });
  });

  group('removeDaysExplicitly', () {
    test('deletes the named days and their content, renumbering what remains', () {
      final container = containerWithDays([
        Day(id: 'd1', index: 1),
        Day(id: 'd2', index: 2, segments: [segmentWithNode('s2')]),
        Day(id: 'd3', index: 3),
      ]);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).removeDaysExplicitly({'d2'});

      final trip = container.read(currentTripProvider);
      expect(trip.days.map((d) => d.id).toList(), ['d1', 'd3']);
      expect(trip.days.map((d) => d.index).toList(), [1, 2]);
    });
  });

  group('setDayCount', () {
    test('growing the trip appends blank route days', () {
      final container = containerWithDays([Day(id: 'd1', index: 1)]);
      addTearDown(container.dispose);

      final beyond = container.read(currentTripProvider.notifier).setDayCount(3);

      expect(beyond, isEmpty);
      final trip = container.read(currentTripProvider);
      expect(trip.days, hasLength(3));
      expect(trip.days.map((d) => d.index).toList(), [1, 2, 3]);
      expect(trip.days[1].kind, 'route');
      expect(trip.days[1].segments, isEmpty);
    });

    test('shrinking drops only empty trailing days, like reduceDayCount', () {
      final container = containerWithDays([
        Day(id: 'd1', index: 1, segments: [segmentWithNode('s1')]),
        Day(id: 'd2', index: 2),
        Day(id: 'd3', index: 3),
      ]);
      addTearDown(container.dispose);

      final beyond = container.read(currentTripProvider.notifier).setDayCount(1);

      expect(beyond, isEmpty);
      expect(container.read(currentTripProvider).days, hasLength(1));
    });

    test('shrinking past content-holding days leaves them and reports them', () {
      final container = containerWithDays([
        Day(id: 'd1', index: 1),
        Day(id: 'd2', index: 2, segments: [segmentWithNode('s2')]),
      ]);
      addTearDown(container.dispose);

      final beyond = container.read(currentTripProvider.notifier).setDayCount(1);

      expect(beyond.map((d) => d.id).toList(), ['d2']);
      expect(container.read(currentTripProvider).days, hasLength(2));
    });

    test('holding the count steady is a no-op', () {
      final container = containerWithDays([Day(id: 'd1', index: 1), Day(id: 'd2', index: 2)]);
      addTearDown(container.dispose);

      final beyond = container.read(currentTripProvider.notifier).setDayCount(2);

      expect(beyond, isEmpty);
      expect(container.read(currentTripProvider).days, hasLength(2));
    });

    test('a negative target is rejected', () {
      final container = containerWithDays([Day(id: 'd1', index: 1)]);
      addTearDown(container.dispose);

      expect(
        () => container.read(currentTripProvider.notifier).setDayCount(-1),
        throwsArgumentError,
      );
    });

    test('records the day count on Trip.duration when no dates are set', () {
      final container = containerWithDays([Day(id: 'd1', index: 1)]);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).setDayCount(4);

      expect(container.read(currentTripProvider).duration?.dayCount, 4);
    });

    test('never overwrites an explicit start/end date range', () {
      final container = containerWithDays([Day(id: 'd1', index: 1)]);
      container.read(currentTripProvider.notifier).setDuration(
            TripDuration(startDate: '2026-09-01', endDate: '2026-09-05'),
          );
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).setDayCount(6);

      final duration = container.read(currentTripProvider).duration;
      expect(duration?.startDate, '2026-09-01');
      expect(duration?.endDate, '2026-09-05');
    });
  });

  group('setDayLocation / setDayTitle / setDayNote', () {
    test('setDayLocation sets a rest day\'s point', () {
      final container = containerWithDays([Day(id: 'd1', index: 1, kind: 'rest')]);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).setDayLocation('d1', const [-105.3, 40.0]);

      expect(container.read(currentTripProvider).days.single.location, const [-105.3, 40.0]);
    });

    test('setDayLocation with null clears an existing location', () {
      final container = containerWithDays(
        [Day(id: 'd1', index: 1, kind: 'rest', location: const [1.0, 2.0])],
      );
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).setDayLocation('d1', null);

      expect(container.read(currentTripProvider).days.single.location, isNull);
    });

    test('setDayTitle/setDayNote write itinerary detail, and an empty string clears it', () {
      final container = containerWithDays([Day(id: 'd1', index: 1, kind: 'rest')]);
      addTearDown(container.dispose);
      final notifier = container.read(currentTripProvider.notifier);

      notifier.setDayTitle('d1', 'Historic district');
      notifier.setDayNote('d1', 'Wander the main street shops.');
      var day = container.read(currentTripProvider).days.single;
      expect(day.title, 'Historic district');
      expect(day.note, 'Wander the main street shops.');

      notifier.setDayTitle('d1', '');
      notifier.setDayNote('d1', '');
      day = container.read(currentTripProvider).days.single;
      expect(day.title, isNull);
      expect(day.note, isNull);
    });
  });

  group('mergeDaysIntoAdjacent', () {
    test('merges a middle day into the previous day and renumbers', () {
      final container = containerWithDays([
        Day(id: 'd1', index: 1, segments: [segmentWithNode('s1')]),
        Day(id: 'd2', index: 2, segments: [segmentWithNode('s2')]),
        Day(id: 'd3', index: 3, segments: [segmentWithNode('s3')]),
      ]);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).mergeDaysIntoAdjacent({'d2'});

      final trip = container.read(currentTripProvider);
      expect(trip.days.map((d) => d.id).toList(), ['d1', 'd3']);
      final merged = trip.days.firstWhere((d) => d.id == 'd1');
      expect(merged.segments.map((s) => s.id).toSet(), {'s1', 's2'});
      expect(trip.days.map((d) => d.index).toList(), [1, 2]);
    });

    test('day 1 merges forward into the next day when there is no previous day', () {
      final container = containerWithDays([
        Day(id: 'd1', index: 1, segments: [segmentWithNode('s1')]),
        Day(id: 'd2', index: 2, segments: [segmentWithNode('s2')]),
      ]);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).mergeDaysIntoAdjacent({'d1'});

      final trip = container.read(currentTripProvider);
      expect(trip.days, hasLength(1));
      final merged = trip.days.single;
      expect(merged.id, 'd2');
      expect(merged.segments.map((s) => s.id).toSet(), {'s1', 's2'});
      expect(merged.index, 1);
    });

    test('merging two adjacent days from the tail backward keeps all their content', () {
      final container = containerWithDays([
        Day(id: 'd1', index: 1, segments: [segmentWithNode('s1')]),
        Day(id: 'd2', index: 2, segments: [segmentWithNode('s2')]),
        Day(id: 'd3', index: 3, segments: [segmentWithNode('s3')]),
      ]);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).mergeDaysIntoAdjacent({'d2', 'd3'});

      final trip = container.read(currentTripProvider);
      expect(trip.days, hasLength(1));
      final merged = trip.days.single;
      expect(merged.id, 'd1');
      expect(merged.segments.map((s) => s.id).toSet(), {'s1', 's2', 's3'});
    });
  });
}
