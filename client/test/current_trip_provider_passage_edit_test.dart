// Story Q2 (issue #122), FR139/FR140 — a passage's mode and endpoints are
// editable after routing (marking the route stale rather than re-solving,
// like `updateSegmentShape` already does per `current_trip_provider_shape_
// test.dart`), and removing a passage never deletes its anchors with it —
// they survive unattached on the day, findable through the curation
// workspace's anchors view (N4a) rather than disappearing.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

void main() {
  ProviderContainer containerWithSegment(Segment segment, {List<Node> dayNodes = const []}) {
    final day = Day(id: 'day-1', index: 1, segments: [segment], nodes: dayNodes);
    final container = ProviderContainer();
    container.read(currentTripProvider.notifier).open(
          Trip(
            id: 't1',
            title: 'Test trip',
            createdAt: '2026-01-01T00:00:00Z',
            updatedAt: '2026-01-01T00:00:00Z',
            days: [day],
          ),
        );
    return container;
  }

  group('updateSegmentMode', () {
    test('changes mode only and marks the route stale rather than re-solving', () {
      final segment = Segment(
        id: 'seg-1',
        mode: 'cycling',
        shape: 'point_to_point',
        start: const [-105.27, 40.02],
        end: const [-105.20, 40.05],
        solve: SolveProvenance(solvedAt: '2026-01-01T00:00:00Z'),
      );
      final container = containerWithSegment(segment);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).updateSegmentMode('day-1', 'seg-1', 'hiking');

      final updated = container.read(currentTripProvider).days.single.segments.single;
      expect(updated.mode, 'hiking');
      expect(updated.shape, 'point_to_point');
      expect(updated.solve?.stale, isTrue);
    });
  });

  group('updateSegmentEndpoints', () {
    test('updates start/end and marks the route stale', () {
      final segment = Segment(
        id: 'seg-1',
        mode: 'cycling',
        shape: 'point_to_point',
        start: const [-105.27, 40.02],
        end: const [-105.20, 40.05],
        solve: SolveProvenance(solvedAt: '2026-01-01T00:00:00Z'),
      );
      final container = containerWithSegment(segment);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).updateSegmentEndpoints(
            'day-1',
            'seg-1',
            start: const [-105.30, 40.10],
            end: const [-105.25, 40.15],
          );

      final updated = container.read(currentTripProvider).days.single.segments.single;
      expect(updated.start, const [-105.30, 40.10]);
      expect(updated.end, const [-105.25, 40.15]);
      expect(updated.solve?.stale, isTrue);
    });
  });

  group('removeSegment', () {
    test('deletes the segment but moves its nodes onto the day, never discarding them', () {
      final node = Node(id: 'n1', kind: NodeKind.poi, coord: const [0, 0], title: 'Overlook');
      final segment = Segment(id: 'seg-1', mode: 'cycling', shape: 'loop', nodes: [node]);
      final container = containerWithSegment(segment);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).removeSegment('day-1', 'seg-1');

      final day = container.read(currentTripProvider).days.single;
      expect(day.segments, isEmpty);
      expect(day.nodes.map((n) => n.id), ['n1']);
    });

    test('existing day-scoped nodes survive alongside the newly unattached ones', () {
      final dayNode = Node(id: 'd1', kind: NodeKind.poi, coord: const [0, 0]);
      final segNode = Node(id: 's1', kind: NodeKind.poi, coord: const [0, 0]);
      final segment = Segment(id: 'seg-1', mode: 'cycling', shape: 'loop', nodes: [segNode]);
      final container = containerWithSegment(segment, dayNodes: [dayNode]);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).removeSegment('day-1', 'seg-1');

      final day = container.read(currentTripProvider).days.single;
      expect(day.nodes.map((n) => n.id).toSet(), {'d1', 's1'});
    });

    test('a bare segment with no nodes removes cleanly with nothing left behind', () {
      final segment = Segment(id: 'seg-1', mode: 'cycling', shape: 'loop');
      final container = containerWithSegment(segment);
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).removeSegment('day-1', 'seg-1');

      final day = container.read(currentTripProvider).days.single;
      expect(day.segments, isEmpty);
      expect(day.nodes, isEmpty);
    });
  });
}
