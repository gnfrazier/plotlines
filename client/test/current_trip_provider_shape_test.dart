// Story A7 (issue #24) — route shape is selectable independently of
// weights. `updateSegmentShape` (the Route tab's shape chips) touches
// `Segment.shape` and nothing else, the same "wholesale-replace one field"
// idiom `updateSegmentVia`/`updateSegmentWeights` already follow
// (`current_trip_provider_spine_test.dart`), and `updateSegmentWeights`
// touches `Segment.weights` and nothing else in return — neither editor can
// clobber the other's authored value.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

void main() {
  Trip tripWithOneSegment(ProviderContainer container) {
    final segment = Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.27, 40.02],
      end: const [-105.20, 40.05],
      weights: WeightProfile(name: 'custom', climbing: 3.0, traffic: 1.5),
      bands: [Band(attribute: 'distance_m', min: 10000, max: 20000)],
      targetDistance: TargetDistance(valueM: 15000),
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

  test('updateSegmentShape changes shape only — weights survive untouched', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    tripWithOneSegment(container);

    container.read(currentTripProvider.notifier).updateSegmentShape('day-1', 'seg-1', 'loop');

    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.shape, 'loop');
    expect(segment.weights?.climbing, 3.0);
    expect(segment.weights?.traffic, 1.5);
  });

  test('updateSegmentWeights changes weights only — shape survives untouched', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    tripWithOneSegment(container);

    container.read(currentTripProvider.notifier).updateSegmentWeights(
          'day-1',
          'seg-1',
          WeightProfile(name: 'custom', climbing: 4.5),
        );

    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.weights?.climbing, 4.5);
    expect(segment.shape, 'point_to_point');
  });

  test('every one of the three shapes is a legal value to switch to', () {
    for (final shape in ['loop', 'out_and_back', 'point_to_point']) {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      tripWithOneSegment(container);

      container.read(currentTripProvider.notifier).updateSegmentShape('day-1', 'seg-1', shape);

      expect(container.read(currentTripProvider).days.single.segments.single.shape, shape);
    }
  });

  test('updateSegmentShape marks the segment stale — an authored-input edit '
      'the geometry no longer matches until a re-solve (ARCH D30)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    tripWithOneSegment(container);

    container.read(currentTripProvider.notifier).updateSegmentShape('day-1', 'seg-1', 'loop');

    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.solve?.stale, isTrue);
  });
}
