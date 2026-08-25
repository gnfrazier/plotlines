// FR118 (Story A0a) — the two mutating affordances the deviation panel
// offers beyond band/via edits (already covered by
// `current_trip_provider_spine_test.dart`): "move one to another day" and
// "split the day."
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

void main() {
  Trip openTwoDayTrip(ProviderContainer container) {
    final seg1 = Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.27, 40.02],
      end: const [-105.20, 40.05],
      via: const [
        [-105.25, 40.03],
        [-105.24, 40.04],
        [-105.23, 40.045],
      ],
      weights: WeightProfile(name: 'custom', climbing: 3.0),
      solve: SolveProvenance(solvedAt: '2026-01-01T00:00:00Z'),
    );
    final seg2 = Segment(
      id: 'seg-2',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.10, 40.10],
      end: const [-105.05, 40.12],
      via: const [
        [-105.08, 40.11],
      ],
    );
    final day1 = Day(id: 'day-1', index: 1, segments: [seg1]);
    final day2 = Day(id: 'day-2', index: 2, segments: [seg2]);
    final day3Empty = Day(id: 'day-3', index: 3); // rest/blank — no segments
    container.read(currentTripProvider.notifier).open(
          Trip(
            id: 't1',
            title: 'Test trip',
            createdAt: '2026-01-01T00:00:00Z',
            updatedAt: '2026-01-01T00:00:00Z',
            days: [day1, day2, day3Empty],
          ),
        );
    return container.read(currentTripProvider);
  }

  group('moveViaToDay', () {
    test('drops the coord from the source segment and appends it to the target '
        'day\'s first segment', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTwoDayTrip(container);

      container.read(currentTripProvider.notifier).moveViaToDay(
            'day-1',
            'seg-1',
            const [-105.24, 40.04],
            'day-2',
          );

      final trip = container.read(currentTripProvider);
      final source = trip.days.firstWhere((d) => d.id == 'day-1').segments.single;
      final target = trip.days.firstWhere((d) => d.id == 'day-2').segments.single;
      expect(source.via, const [
        [-105.25, 40.03],
        [-105.23, 40.045],
      ]);
      expect(target.via, const [
        [-105.08, 40.11],
        [-105.24, 40.04],
      ]);
    });

    test('marks the source segment stale — the spine it re-solves against changed', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTwoDayTrip(container);

      container.read(currentTripProvider.notifier).moveViaToDay(
            'day-1',
            'seg-1',
            const [-105.24, 40.04],
            'day-2',
          );

      final trip = container.read(currentTripProvider);
      final source = trip.days.firstWhere((d) => d.id == 'day-1').segments.single;
      expect(source.solve?.stale, isTrue);
    });

    test('touches nothing else on the source segment — weights survive', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTwoDayTrip(container);

      container.read(currentTripProvider.notifier).moveViaToDay(
            'day-1',
            'seg-1',
            const [-105.24, 40.04],
            'day-2',
          );

      final trip = container.read(currentTripProvider);
      final source = trip.days.firstWhere((d) => d.id == 'day-1').segments.single;
      expect(source.weights?.climbing, 3.0);
    });
  });

  group('splitDayAt', () {
    test('moves the tail of the spine onto a new day, keeping the head on the '
        'original segment', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTwoDayTrip(container);

      final newDayId =
          container.read(currentTripProvider.notifier).splitDayAt('day-1', 'seg-1', 1);

      final trip = container.read(currentTripProvider);
      final original = trip.days.firstWhere((d) => d.id == 'day-1').segments.single;
      expect(original.via, const [
        [-105.25, 40.03],
      ]);

      final newDay = trip.days.firstWhere((d) => d.id == newDayId);
      expect(newDay.segments, hasLength(1));
      final newSegment = newDay.segments.single;
      expect(newSegment.start, const [-105.24, 40.04]);
      expect(newSegment.via, const [
        [-105.23, 40.045],
      ]);
    });

    test('the new segment carries over mode, shape and end for point_to_point', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTwoDayTrip(container);

      final newDayId =
          container.read(currentTripProvider.notifier).splitDayAt('day-1', 'seg-1', 1);

      final trip = container.read(currentTripProvider);
      final newSegment = trip.days.firstWhere((d) => d.id == newDayId).segments.single;
      expect(newSegment.mode, 'cycling');
      expect(newSegment.shape, 'point_to_point');
      expect(newSegment.end, const [-105.20, 40.05]);
    });

    test('a loop shape carries no end into the new segment — it has none of its own',
        () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final seg = Segment(
        id: 'loop-seg',
        mode: 'cycling',
        shape: 'loop',
        start: const [-105.27, 40.02],
        via: const [
          [-105.25, 40.03],
          [-105.24, 40.04],
        ],
      );
      container.read(currentTripProvider.notifier).open(
            Trip(
              id: 't1',
              title: 'Loop trip',
              createdAt: '2026-01-01T00:00:00Z',
              updatedAt: '2026-01-01T00:00:00Z',
              days: [
                Day(id: 'day-1', index: 1, segments: [seg]),
              ],
            ),
          );

      final newDayId =
          container.read(currentTripProvider.notifier).splitDayAt('day-1', 'loop-seg', 1);
      final newSegment =
          container.read(currentTripProvider).days.firstWhere((d) => d.id == newDayId).segments.single;
      expect(newSegment.end, isNull);
    });

    test('rejects a split with no head', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTwoDayTrip(container);

      expect(
        () => container.read(currentTripProvider.notifier).splitDayAt('day-1', 'seg-1', 0),
        throwsArgumentError,
      );
    });

    test('rejects a split with no tail', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTwoDayTrip(container);

      expect(
        () => container.read(currentTripProvider.notifier).splitDayAt('day-1', 'seg-1', 3),
        throwsArgumentError,
      );
    });
  });
}
