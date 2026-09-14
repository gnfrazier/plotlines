// Issue #388 — #45/#46 both flagged, in their closing comments, that
// removing an anchor or segment a Hazard/Permit points at left a dangling
// `anchorId`/`nodeId`/`segmentId`, a pre-existing gap shared by both types
// and predating either story. The policy picked here mirrors #384's
// existing fix for `Role.dayId`/`segmentId`: the pointer detaches (goes
// `null`) rather than dangling or destroying the Hazard/Permit itself — a
// hazard is never dropped (FR115) and a permit is authored work, so removal
// of what either was pinned to leaves it unattached, not gone.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

void main() {
  ProviderContainer containerWithTrip(Trip trip) {
    final container = ProviderContainer();
    container.read(currentTripProvider.notifier).open(trip);
    return container;
  }

  group('removeAnchor', () {
    test('detaches a Hazard.anchorId pinned to the removed anchor, leaving the hazard itself', () {
      final container = containerWithTrip(Trip(
        id: 't1',
        title: 'Test trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        anchors: [
          Anchor(id: 'a1', coord: const [0, 0], roles: [Role(id: 'r1', kind: RoleKind.narrative)]),
        ],
        days: [
          Day(id: 'd1', index: 1, hazards: [
            Hazard(id: 'h1', severity: 'high', anchorId: 'a1'),
          ]),
        ],
      ));
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).removeAnchor('a1');

      final trip = container.read(currentTripProvider);
      expect(trip.anchors, isEmpty);
      final hazard = trip.days.single.hazards.single;
      expect(hazard.id, 'h1');
      expect(hazard.anchorId, isNull);
    });

    test('detaches a segment-level Hazard.anchorId too', () {
      final container = containerWithTrip(Trip(
        id: 't1',
        title: 'Test trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        anchors: [
          Anchor(id: 'a1', coord: const [0, 0], roles: [Role(id: 'r1', kind: RoleKind.narrative)]),
        ],
        days: [
          Day(id: 'd1', index: 1, segments: [
            Segment(
              id: 's1',
              mode: 'cycling',
              shape: 'loop',
              hazards: [Hazard(id: 'h1', severity: 'caution', anchorId: 'a1')],
            ),
          ]),
        ],
      ));
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).removeAnchor('a1');

      final hazard = container.read(currentTripProvider).days.single.segments.single.hazards.single;
      expect(hazard.anchorId, isNull);
    });

    test('detaches a Permit.anchorId pinned to the removed anchor, leaving the permit itself', () {
      final container = containerWithTrip(Trip(
        id: 't1',
        title: 'Test trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        anchors: [
          Anchor(id: 'a1', coord: const [0, 0], roles: [Role(id: 'r1', kind: RoleKind.narrative)]),
        ],
        days: [Day(id: 'd1', index: 1)],
        permits: [Permit(id: 'p1', title: 'Backcountry permit', anchorId: 'a1')],
      ));
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).removeAnchor('a1');

      final permit = container.read(currentTripProvider).permits.single;
      expect(permit.id, 'p1');
      expect(permit.anchorId, isNull);
    });

    test('a hazard/permit pinned to a different anchor is left untouched', () {
      final container = containerWithTrip(Trip(
        id: 't1',
        title: 'Test trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        anchors: [
          Anchor(id: 'a1', coord: const [0, 0], roles: [Role(id: 'r1', kind: RoleKind.narrative)]),
          Anchor(id: 'a2', coord: const [1, 1], roles: [Role(id: 'r2', kind: RoleKind.narrative)]),
        ],
        days: [
          Day(id: 'd1', index: 1, hazards: [Hazard(id: 'h1', severity: 'high', anchorId: 'a2')]),
        ],
        permits: [Permit(id: 'p1', title: 'Pass', anchorId: 'a2')],
      ));
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).removeAnchor('a1');

      final trip = container.read(currentTripProvider);
      expect(trip.days.single.hazards.single.anchorId, 'a2');
      expect(trip.permits.single.anchorId, 'a2');
    });
  });

  group('removeSegment', () {
    test('detaches a Permit.segmentId pinned to the removed passage', () {
      final container = containerWithTrip(Trip(
        id: 't1',
        title: 'Test trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: [
          Day(id: 'd1', index: 1, segments: [Segment(id: 's1', mode: 'cycling', shape: 'loop')]),
        ],
        permits: [Permit(id: 'p1', title: 'Land access', segmentId: 's1')],
      ));
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).removeSegment('d1', 's1');

      final permit = container.read(currentTripProvider).permits.single;
      expect(permit.segmentId, isNull);
    });
  });

  group('removeNodesById', () {
    test('detaches a Hazard.nodeId pinned to a removed node', () {
      final container = containerWithTrip(Trip(
        id: 't1',
        title: 'Test trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: [
          Day(id: 'd1', index: 1, nodes: [
            Node(id: 'n1', kind: NodeKind.poi, coord: const [0, 0]),
          ], hazards: [
            Hazard(id: 'h1', severity: 'mandatory_reroute', nodeId: 'n1'),
          ]),
        ],
      ));
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).removeNodesById({'n1'});

      final trip = container.read(currentTripProvider);
      expect(trip.days.single.nodes, isEmpty);
      final hazard = trip.days.single.hazards.single;
      expect(hazard.id, 'h1');
      expect(hazard.nodeId, isNull);
    });

    test('a hazard pinned to a node that stays is untouched', () {
      final container = containerWithTrip(Trip(
        id: 't1',
        title: 'Test trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: [
          Day(id: 'd1', index: 1, nodes: [
            Node(id: 'keep', kind: NodeKind.poi, coord: const [0, 0]),
            Node(id: 'drop', kind: NodeKind.poi, coord: const [1, 1]),
          ], hazards: [
            Hazard(id: 'h1', severity: 'caution', nodeId: 'keep'),
          ]),
        ],
      ));
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).removeNodesById({'drop'});

      expect(container.read(currentTripProvider).days.single.hazards.single.nodeId, 'keep');
    });
  });

  group('removeDaysExplicitly', () {
    test('detaches a Permit.segmentId scoped to a passage on the removed day', () {
      final container = containerWithTrip(Trip(
        id: 't1',
        title: 'Test trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: [
          Day(id: 'd1', index: 1),
          Day(id: 'd2', index: 2, segments: [Segment(id: 's2', mode: 'hiking', shape: 'loop')]),
        ],
        permits: [Permit(id: 'p1', title: 'Trailhead pass', segmentId: 's2')],
      ));
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).removeDaysExplicitly({'d2'});

      expect(container.read(currentTripProvider).permits.single.segmentId, isNull);
    });

    test('detaches a Hazard.nodeId on a surviving day scoped to a node the removed day carried', () {
      final container = containerWithTrip(Trip(
        id: 't1',
        title: 'Test trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: [
          Day(id: 'd1', index: 1, hazards: [
            Hazard(id: 'h1', severity: 'high', nodeId: 'n2'),
          ]),
          Day(id: 'd2', index: 2, nodes: [Node(id: 'n2', kind: NodeKind.poi, coord: const [0, 0])]),
        ],
      ));
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).removeDaysExplicitly({'d2'});

      final trip = container.read(currentTripProvider);
      expect(trip.days.single.id, 'd1');
      expect(trip.days.single.hazards.single.nodeId, isNull);
    });
  });

  group('mergeDaysIntoAdjacent', () {
    test('a merged-away day\'s content moves, so its Permit.segmentId survives untouched', () {
      final container = containerWithTrip(Trip(
        id: 't1',
        title: 'Test trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: [
          Day(id: 'd1', index: 1),
          Day(id: 'd2', index: 2, segments: [Segment(id: 's2', mode: 'hiking', shape: 'loop')]),
        ],
        permits: [Permit(id: 'p1', title: 'Trailhead pass', segmentId: 's2')],
      ));
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).mergeDaysIntoAdjacent({'d2'});

      final trip = container.read(currentTripProvider);
      expect(trip.days.single.segments.single.id, 's2');
      expect(trip.permits.single.segmentId, 's2');
    });

    test('merging the trip\'s only day down to nothing detaches a Permit.segmentId it carried', () {
      final container = containerWithTrip(Trip(
        id: 't1',
        title: 'Test trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: [
          Day(id: 'd1', index: 1, segments: [Segment(id: 's1', mode: 'hiking', shape: 'loop')]),
        ],
        permits: [Permit(id: 'p1', title: 'Trailhead pass', segmentId: 's1')],
      ));
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).mergeDaysIntoAdjacent({'d1'});

      final trip = container.read(currentTripProvider);
      expect(trip.days, isEmpty);
      final permit = trip.permits.single;
      expect(permit.id, 'p1');
      expect(permit.segmentId, isNull);
    });
  });
}
