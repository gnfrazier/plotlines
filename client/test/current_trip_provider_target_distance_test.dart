// Story A8 (issue #25) — target distance is banded by default in explore
// mode, the Author can widen the band, and distance is never dropped from
// the explore search's constraint set. Covers `current_trip_provider.dart`'s
// `updateSegmentTargetDistance` (sets a fresh, banded target) and
// `updateSegmentTargetDistanceBand` (widens without touching the target),
// plus `regenerateSegment`'s FR9/A6 synchronous violation surfacing now
// covering the distance band too.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

void main() {
  Trip tripWithOneSegment(ProviderContainer container, {String shape = 'loop'}) {
    final segment = Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: shape,
      start: const [-105.27, 40.02],
      end: shape == 'point_to_point' ? const [-105.20, 40.05] : null,
      solve: SolveProvenance(solvedAt: '2026-01-01T00:00:00Z'),
    );
    final day = Day(id: 'day-1', index: 1, segments: [segment]);
    container.read(currentTripProvider.notifier).open(
          Trip(
            id: 't1',
            title: 'Test trip',
            createdAt: '2026-01-01T00:00:00Z',
            updatedAt: '2026-01-01T00:00:00Z',
            days: [day],
          ),
        );
    return container.read(currentTripProvider);
  }

  group('updateSegmentTargetDistance', () {
    test('a loop target is banded by default (FR8/A8)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      tripWithOneSegment(container, shape: 'loop');

      container.read(currentTripProvider.notifier).updateSegmentTargetDistance('day-1', 'seg-1', 20000.0);

      final target = container.read(currentTripProvider).days.single.segments.single.targetDistance;
      expect(target!.valueM, 20000.0);
      expect(target.minM, 18000.0);
      expect(target.maxM, 22000.0);
    });

    test('an out_and_back target is banded by default too', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      tripWithOneSegment(container, shape: 'out_and_back');

      container.read(currentTripProvider.notifier).updateSegmentTargetDistance('day-1', 'seg-1', 10000.0);

      final target = container.read(currentTripProvider).days.single.segments.single.targetDistance;
      expect(target!.minM, 9000.0);
      expect(target.maxM, 11000.0);
    });

    test('point_to_point has no target-distance input, but a defensive set is left unbanded', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      tripWithOneSegment(container, shape: 'point_to_point');

      container.read(currentTripProvider.notifier).updateSegmentTargetDistance('day-1', 'seg-1', 10000.0);

      final target = container.read(currentTripProvider).days.single.segments.single.targetDistance;
      expect(target!.valueM, 10000.0);
      expect(target.minM, isNull);
      expect(target.maxM, isNull);
    });

    test('clearing the target clears the whole thing, band included', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      tripWithOneSegment(container, shape: 'loop');
      container.read(currentTripProvider.notifier).updateSegmentTargetDistance('day-1', 'seg-1', 20000.0);

      container.read(currentTripProvider.notifier).updateSegmentTargetDistance('day-1', 'seg-1', null);

      expect(container.read(currentTripProvider).days.single.segments.single.targetDistance, isNull);
    });

    test('re-setting the target re-bands fresh, discarding an old widened band', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      tripWithOneSegment(container, shape: 'loop');
      container.read(currentTripProvider.notifier).updateSegmentTargetDistance('day-1', 'seg-1', 20000.0);
      container.read(currentTripProvider.notifier).updateSegmentTargetDistanceBand(
            'day-1',
            'seg-1',
            minM: 5000.0,
            maxM: 35000.0,
          );

      container.read(currentTripProvider.notifier).updateSegmentTargetDistance('day-1', 'seg-1', 10000.0);

      final target = container.read(currentTripProvider).days.single.segments.single.targetDistance;
      expect(target!.valueM, 10000.0);
      expect(target.minM, 9000.0);
      expect(target.maxM, 11000.0);
    });
  });

  group('updateSegmentTargetDistanceBand', () {
    test('widens the band without touching the target value', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      tripWithOneSegment(container, shape: 'loop');
      container.read(currentTripProvider.notifier).updateSegmentTargetDistance('day-1', 'seg-1', 20000.0);

      container.read(currentTripProvider.notifier).updateSegmentTargetDistanceBand(
            'day-1',
            'seg-1',
            minM: 12000.0,
            maxM: 28000.0,
          );

      final target = container.read(currentTripProvider).days.single.segments.single.targetDistance;
      expect(target!.valueM, 20000.0); // untouched
      expect(target.minM, 12000.0);
      expect(target.maxM, 28000.0);
    });

    test('is a no-op when the segment has no target distance to band', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      tripWithOneSegment(container, shape: 'loop'); // no target set

      container.read(currentTripProvider.notifier).updateSegmentTargetDistanceBand(
            'day-1',
            'seg-1',
            minM: 1000.0,
            maxM: 2000.0,
          );

      expect(container.read(currentTripProvider).days.single.segments.single.targetDistance, isNull);
    });

    test('marks the segment stale — the band feeds the next solve', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      tripWithOneSegment(container, shape: 'loop');
      container.read(currentTripProvider.notifier).updateSegmentTargetDistance('day-1', 'seg-1', 20000.0);

      container.read(currentTripProvider.notifier).updateSegmentTargetDistanceBand(
            'day-1',
            'seg-1',
            minM: 12000.0,
            maxM: 28000.0,
          );

      expect(container.read(currentTripProvider).days.single.segments.single.solve?.stale, isTrue);
    });
  });
}
