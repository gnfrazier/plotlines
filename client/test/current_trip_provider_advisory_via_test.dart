// Story A9a (issue #27) — three or more via-anchors on an explore loop make
// the target distance advisory. Covers `current_trip_provider.dart`'s wiring:
// `updateSegmentTargetDistance` marks a fresh band advisory when the spine
// already has three via-anchors, and `updateSegmentVia` keeps an existing
// band's `advisory` flag in step as via-anchors are added or removed.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

void main() {
  Segment segmentOf(ProviderContainer c) =>
      c.read(currentTripProvider).days.single.segments.single;

  void openWith(ProviderContainer container, Segment segment) {
    container.read(currentTripProvider.notifier).open(
          Trip(
            id: 't1',
            title: 'Test trip',
            createdAt: '2026-01-01T00:00:00Z',
            updatedAt: '2026-01-01T00:00:00Z',
            days: [Day(id: 'day-1', index: 1, segments: [segment])],
          ),
        );
  }

  Segment loopSegment({List<Coord> via = const []}) => Segment(
        id: 'seg-1',
        mode: 'cycling',
        shape: 'loop',
        start: const [-105.27, 40.02],
        via: via,
        solve: SolveProvenance(solvedAt: '2026-01-01T00:00:00Z'),
      );

  group('updateSegmentTargetDistance', () {
    test('with fewer than three via-anchors the fresh band is not advisory', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openWith(container, loopSegment(via: const [
        [-105.26, 40.03],
        [-105.25, 40.04],
      ]));

      container
          .read(currentTripProvider.notifier)
          .updateSegmentTargetDistance('day-1', 'seg-1', 20000.0);

      final target = segmentOf(container).targetDistance!;
      expect(target.minM, 18000.0);
      expect(target.maxM, 22000.0);
      expect(target.advisory ?? false, isFalse);
    });

    test('with three via-anchors the fresh band is banded and advisory', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openWith(container, loopSegment(via: const [
        [-105.26, 40.03],
        [-105.25, 40.04],
        [-105.24, 40.05],
      ]));

      container
          .read(currentTripProvider.notifier)
          .updateSegmentTargetDistance('day-1', 'seg-1', 20000.0);

      final target = segmentOf(container).targetDistance!;
      expect(target.minM, 18000.0);
      expect(target.maxM, 22000.0);
      expect(target.advisory, isTrue);
    });
  });

  group('updateSegmentVia keeps the advisory flag in step', () {
    test('adding a third via-anchor flips an existing band to advisory', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openWith(container, loopSegment(via: const [
        [-105.26, 40.03],
        [-105.25, 40.04],
      ]));
      final notifier = container.read(currentTripProvider.notifier);
      notifier.updateSegmentTargetDistance('day-1', 'seg-1', 20000.0);
      expect(segmentOf(container).targetDistance!.advisory ?? false, isFalse);

      notifier.updateSegmentVia('day-1', 'seg-1', const [
        [-105.26, 40.03],
        [-105.25, 40.04],
        [-105.24, 40.05],
      ]);

      expect(segmentOf(container).targetDistance!.advisory, isTrue);
    });

    test('dropping back below three restores an enforced band', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openWith(container, loopSegment(via: const [
        [-105.26, 40.03],
        [-105.25, 40.04],
        [-105.24, 40.05],
      ]));
      final notifier = container.read(currentTripProvider.notifier);
      notifier.updateSegmentTargetDistance('day-1', 'seg-1', 20000.0);
      expect(segmentOf(container).targetDistance!.advisory, isTrue);

      notifier.updateSegmentVia('day-1', 'seg-1', const [
        [-105.26, 40.03],
        [-105.25, 40.04],
      ]);

      expect(segmentOf(container).targetDistance!.advisory, isFalse);
      // the band values themselves are untouched — only the flag moved
      expect(segmentOf(container).targetDistance!.minM, 18000.0);
      expect(segmentOf(container).targetDistance!.maxM, 22000.0);
    });

    test('a segment with no target distance is left alone', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openWith(container, loopSegment());

      container.read(currentTripProvider.notifier).updateSegmentVia('day-1', 'seg-1', const [
        [-105.26, 40.03],
        [-105.25, 40.04],
        [-105.24, 40.05],
      ]);

      expect(segmentOf(container).targetDistance, isNull);
    });
  });
}
