// FR117/A0 — compose mode's spine editor (`WeightsRail`'s `_SpineEditor`)
// goes through `CurrentTripNotifier.updateSegmentVia`: replacing a
// segment's via-anchor order wholesale and marking it stale for re-solve,
// the same way the existing weights/bands/shape editors already do.
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
      via: const [
        [-105.25, 40.03],
      ],
      weights: WeightProfile(name: 'custom', climbing: 3.0),
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

  test('updateSegmentVia replaces the via list wholesale, in the given order', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    tripWithOneSegment(container);

    container.read(currentTripProvider.notifier).updateSegmentVia('day-1', 'seg-1', const [
      [-105.24, 40.04],
      [-105.22, 40.045],
    ]);

    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.via, const [
      [-105.24, 40.04],
      [-105.22, 40.045],
    ]);
  });

  test('updateSegmentVia marks the segment stale — an authored-input edit '
      'the geometry no longer matches until a re-solve (ARCH D30)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    tripWithOneSegment(container);

    container.read(currentTripProvider.notifier).updateSegmentVia('day-1', 'seg-1', const []);

    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.solve?.stale, isTrue);
  });

  test('updateSegmentVia touches nothing else the Author curated — FR119 '
      "\"no work lost\": weights, bands and the explore target survive", () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    tripWithOneSegment(container);

    container.read(currentTripProvider.notifier).updateSegmentVia('day-1', 'seg-1', const [
      [-105.24, 40.04],
    ]);

    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.weights?.climbing, 3.0);
    expect(segment.bands.single.attribute, 'distance_m');
    expect(segment.targetDistance?.valueM, 15000);
  });

  test('an empty spine is a legal, explicit state — not a validation error', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    tripWithOneSegment(container);

    container.read(currentTripProvider.notifier).updateSegmentVia('day-1', 'seg-1', const []);

    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.via, isEmpty);
  });
}
