// FR21 / C5 — `addProvisionNodeFromProposal`: N4's provision-cluster
// proposals dropped onto a passage as placed rest-stop nodes in one action,
// without going near the proposal-review list (N4a, P1).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/candidate.dart' show RoleAffinity;
import 'package:plotlines_client/domain/cluster_proposal.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

ClusterProposal _provisionProposal({
  List<RoleAffinity> affinities = const [RoleAffinity.provision],
}) =>
    ClusterProposal(
      id: 'cl_1',
      name: 'Depot services',
      kind: affinities.map((a) => a.name).join('+'),
      roleAffinities: affinities,
      members: const [
        ClusterMember(
          candidateId: 'c1',
          layer: 'amenity',
          type: 'amenity=drinking_water',
          salience: 0.6,
          roleAffinity: RoleAffinity.provision,
        ),
      ],
      centroid: const [-82.54, 35.60],
      extentM: 30,
      tightness: 0.9,
      salienceScore: 0.6,
      rankScore: 0.54,
    );

void main() {
  ProviderContainer openTripWithSegment() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final segment = Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-82.60, 35.58],
      end: const [-82.50, 35.63],
    );
    container.read(currentTripProvider.notifier).open(
          Trip(
            id: 't1',
            title: 'Test trip',
            createdAt: '2026-01-01T00:00:00Z',
            updatedAt: '2026-01-01T00:00:00Z',
            days: [Day(id: 'day-1', index: 1, segments: [segment])],
          ),
        );
    return container;
  }

  test('a provision proposal is placed as a rest-stop node on the passage', () {
    final container = openTripWithSegment();
    final notifier = container.read(currentTripProvider.notifier);

    final placed = notifier.addProvisionNodeFromProposal(
      'day-1',
      'seg-1',
      _provisionProposal(),
    );

    expect(placed, isNotNull);
    expect(placed!.kind, NodeKind.restStop);

    final nodes = container.read(currentTripProvider).days.single.segments.single.nodes;
    expect(nodes, hasLength(1));
    expect(nodes.single.id, placed.id);
    expect(nodes.single.title, 'Depot services');
    expect(nodes.single.amenities, ['water']);
  });

  test('a non-provision proposal places nothing and returns null', () {
    final container = openTripWithSegment();
    final notifier = container.read(currentTripProvider.notifier);

    final placed = notifier.addProvisionNodeFromProposal(
      'day-1',
      'seg-1',
      _provisionProposal(affinities: const [RoleAffinity.narrative]),
    );

    expect(placed, isNull);
    expect(
      container.read(currentTripProvider).days.single.segments.single.nodes,
      isEmpty,
    );
  });
}
