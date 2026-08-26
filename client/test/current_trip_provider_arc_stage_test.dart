// Story O6 (issue #13) — a passage's own arc stage. `updateSegmentArcStage`
// (the Route tab's weights rail ARC chips) touches `Segment.arcStage` and
// nothing else, the same "wholesale-replace one field" idiom
// `updateSegmentShape`/`updateSegmentWeights` already follow
// (`current_trip_provider_shape_test.dart`) — with one deliberate
// difference: arc is narrative structure, not a solver input, so unlike
// shape/weights/bands it never marks the segment stale.
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
      weights: WeightProfile(name: 'custom', climbing: 3.0),
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

  test('updateSegmentArcStage sets the arc stage only — shape and weights survive untouched', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    tripWithOneSegment(container);

    container.read(currentTripProvider.notifier).updateSegmentArcStage('day-1', 'seg-1', 'crux');

    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.arcStage, 'crux');
    expect(segment.shape, 'point_to_point');
    expect(segment.weights?.climbing, 3.0);
  });

  test('updateSegmentArcStage(null) clears a previously-set arc stage', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    tripWithOneSegment(container);
    container.read(currentTripProvider.notifier).updateSegmentArcStage('day-1', 'seg-1', 'climax');

    container.read(currentTripProvider.notifier).updateSegmentArcStage('day-1', 'seg-1', null);

    expect(container.read(currentTripProvider).days.single.segments.single.arcStage, isNull);
  });

  test('every arc stage is a legal value to switch to', () {
    for (final stage in ['exposition', 'rising', 'crux', 'climax', 'resolution']) {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      tripWithOneSegment(container);

      container.read(currentTripProvider.notifier).updateSegmentArcStage('day-1', 'seg-1', stage);

      expect(container.read(currentTripProvider).days.single.segments.single.arcStage, stage);
    }
  });

  test('updateSegmentArcStage does NOT mark the segment stale — arc is narrative '
      'structure, not a solver input the geometry could disagree with', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    tripWithOneSegment(container);

    container.read(currentTripProvider.notifier).updateSegmentArcStage('day-1', 'seg-1', 'resolution');

    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.solve?.stale, isNot(isTrue));
  });
}
