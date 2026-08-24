// FR99 (Story N3) — promoting a candidate into the trip, and the bbox-shrink
// seam (N1's `trip_bbox_shrink_prompt.dart`) it completes: `tripAnchorsProvider`
// deriving real anchors from promoted/authored nodes, and `removeNodesById`
// actually carrying out the Author's "remove these anchors" choice.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

void main() {
  Trip tripWithOneDay(ProviderContainer container) {
    final day = Day(id: 'day-1', index: 1, kind: 'rest');
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

  test('promoteCandidate appends a day-scoped node carrying the candidate\'s type', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    tripWithOneDay(container);

    final node = Node(
      id: 'n1',
      kind: NodeKind.poi,
      coord: const [-105.27, 40.02],
      title: 'Old Fort',
      poiType: 'historic',
    );
    container.read(currentTripProvider.notifier).promoteCandidate('day-1', node);

    final trip = container.read(currentTripProvider);
    expect(trip.days.single.nodes, hasLength(1));
    expect(trip.days.single.nodes.single.title, 'Old Fort');
    expect(trip.days.single.nodes.single.poiType, 'historic');
  });

  test('tripAnchorsProvider reflects every promoted/authored node in the trip', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    tripWithOneDay(container);

    expect(container.read(tripAnchorsProvider), isEmpty);

    container.read(currentTripProvider.notifier).promoteCandidate(
          'day-1',
          Node(id: 'n1', kind: NodeKind.poi, coord: const [-105.27, 40.02], title: 'Old Fort'),
        );

    final anchors = container.read(tripAnchorsProvider);
    expect(anchors, hasLength(1));
    expect(anchors.single.id, 'n1');
    expect(anchors.single.label, 'Old Fort');
    expect(anchors.single.point, const [-105.27, 40.02]);
  });

  test('removeNodesById drops exactly the named nodes and nothing else', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    tripWithOneDay(container);
    final notifier = container.read(currentTripProvider.notifier);
    notifier.promoteCandidate(
        'day-1', Node(id: 'keep', kind: NodeKind.poi, coord: const [0, 0], title: 'Keep me'));
    notifier.promoteCandidate(
        'day-1', Node(id: 'drop', kind: NodeKind.poi, coord: const [1, 1], title: 'Drop me'));

    notifier.removeNodesById({'drop'});

    final nodes = container.read(currentTripProvider).days.single.nodes;
    expect(nodes.map((n) => n.id), ['keep']);
  });

  test('removeNodesById with an empty set is a no-op', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    tripWithOneDay(container);
    final notifier = container.read(currentTripProvider.notifier);
    notifier.promoteCandidate(
        'day-1', Node(id: 'keep', kind: NodeKind.poi, coord: const [0, 0]));
    final before = container.read(currentTripProvider).updatedAt;

    notifier.removeNodesById(const {});

    final trip = container.read(currentTripProvider);
    expect(trip.days.single.nodes, hasLength(1));
    expect(trip.updatedAt, before);
  });
}
