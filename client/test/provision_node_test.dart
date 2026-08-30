// FR21 / C5 — waypoints, regroup points, and amenity-tagged rest stops as
// placed nodes, plus the bridge that lets N4/FR104's provision-cluster
// proposals feed straight in. The manual authoring path (kind + amenities on
// a Node) was shipped in the client build but never had coverage; the
// proposal bridge (`provisionNodeFromProposal`) is new.

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/candidate.dart' show RoleAffinity;
import 'package:plotlines_client/domain/cluster_proposal.dart';
import 'package:plotlines_client/domain/domain.dart';

ClusterMember _member(String type, RoleAffinity affinity, {double salience = 0.5}) =>
    ClusterMember(
      candidateId: 'c_$type',
      layer: type.split('=').first,
      type: type,
      salience: salience,
      roleAffinity: affinity,
    );

ClusterProposal _proposal({
  required List<RoleAffinity> affinities,
  required List<ClusterMember> members,
  String name = 'Trailhead services',
  List<double> centroid = const [-82.55, 35.61],
}) =>
    ClusterProposal(
      id: 'cl_test',
      name: name,
      kind: affinities.map((a) => a.name).join('+'),
      roleAffinities: affinities,
      members: members,
      centroid: centroid,
      extentM: 40,
      tightness: 0.8,
      salienceScore: 0.7,
      rankScore: 0.56,
    );

void main() {
  group('AC1/AC2 — a placed node can be a waypoint or be flagged a regroup point', () {
    test('Node.copyWith(kind:) turns a waypoint into a regroup point, keeping the rest', () {
      final waypoint = Node(
        id: 'n1',
        kind: NodeKind.waypoint,
        coord: const [-82.55, 35.61],
        title: 'Bridge',
        note: 'wait here if split',
        distanceAlongM: 1200,
      );

      final regroup = waypoint.copyWith(kind: NodeKind.regroup);

      expect(regroup.kind, NodeKind.regroup);
      expect(regroup.id, 'n1');
      expect(regroup.title, 'Bridge');
      expect(regroup.note, 'wait here if split');
      expect(regroup.distanceAlongM, 1200);
      expect(regroup.coord, const [-82.55, 35.61]);
    });

    test('waypoint / regroup / rest_stop kinds round-trip through JSON', () {
      for (final kind in [NodeKind.waypoint, NodeKind.regroup, NodeKind.restStop]) {
        final node = Node(id: 'n', kind: kind, coord: const [-82.5, 35.6]);
        final back = Node.fromJson(node.toJson());
        expect(back.kind, kind, reason: kind.wireValue);
      }
    });
  });

  group('AC3 — rest stops carry amenity tags', () {
    test('the authoring seed set is exactly water/toilets/food/shelter', () {
      expect(kKnownAmenities, ['water', 'toilets', 'food', 'shelter']);
    });

    test('amenities round-trip on a rest_stop node, order preserved', () {
      final node = Node(
        id: 'r1',
        kind: NodeKind.restStop,
        coord: const [-82.5, 35.6],
        amenities: const ['water', 'toilets'],
      );
      final back = Node.fromJson(node.toJson());
      expect(back.amenities, ['water', 'toilets']);
    });

    test('amenities is an open list — an unlisted tag still round-trips (seed set, not vocabulary)', () {
      final node = Node(
        id: 'r2',
        kind: NodeKind.restStop,
        coord: const [-82.5, 35.6],
        amenities: const ['water', 'bike_repair'],
      );
      expect(Node.fromJson(node.toJson()).amenities, ['water', 'bike_repair']);
    });

    test('an empty amenity set is pruned from the wire form', () {
      final node = Node(id: 'r3', kind: NodeKind.restStop, coord: const [-82.5, 35.6]);
      expect(node.toJson().containsKey('amenities'), isFalse);
    });
  });

  group('amenityForType — OSM key=value → a known amenity', () {
    test('maps the recognised provision types', () {
      expect(amenityForType('amenity=drinking_water'), 'water');
      expect(amenityForType('natural=spring'), 'water');
      expect(amenityForType('amenity=toilets'), 'toilets');
      expect(amenityForType('amenity=cafe'), 'food');
      expect(amenityForType('shop=supermarket'), 'food');
      expect(amenityForType('amenity=shelter'), 'shelter');
      expect(amenityForType('tourism=wilderness_hut'), 'shelter');
    });

    test('is case- and whitespace-insensitive', () {
      expect(amenityForType('  Amenity=Toilets '), 'toilets');
    });

    test('an unrecognised type is null, never a bogus amenity', () {
      expect(amenityForType('tourism=viewpoint'), isNull);
      expect(amenityForType('historic=castle'), isNull);
      expect(amenityForType(''), isNull);
    });

    test('every mapped value is itself one of the seed amenities', () {
      const probes = [
        'amenity=drinking_water',
        'amenity=toilets',
        'amenity=cafe',
        'amenity=shelter',
      ];
      for (final p in probes) {
        expect(kKnownAmenities, contains(amenityForType(p)));
      }
    });
  });

  group('AC4 — N4 provision-cluster proposals feed this directly', () {
    test('a provision proposal becomes one rest_stop node at the centroid, named, amenity-tagged', () {
      final proposal = _proposal(
        affinities: [RoleAffinity.provision],
        name: 'Riverside rest area',
        centroid: const [-82.531, 35.602],
        members: [
          _member('amenity=drinking_water', RoleAffinity.provision),
          _member('amenity=toilets', RoleAffinity.provision),
        ],
      );

      final node = provisionNodeFromProposal(proposal, id: 'n_new');

      expect(node, isNotNull);
      expect(node!.kind, NodeKind.restStop);
      expect(node.coord, const [-82.531, 35.602]);
      expect(node.title, 'Riverside rest area');
      expect(node.amenities, ['toilets', 'water']); // sorted union
    });

    test('only provision members contribute amenities; narrative members are ignored', () {
      final proposal = _proposal(
        affinities: [RoleAffinity.narrative, RoleAffinity.provision],
        members: [
          _member('tourism=viewpoint', RoleAffinity.narrative),
          _member('amenity=cafe', RoleAffinity.provision),
        ],
      );

      final node = provisionNodeFromProposal(proposal, id: 'n_new');

      expect(node!.amenities, ['food']);
    });

    test('a provision proposal whose members map to nothing still places a node, with no amenities', () {
      final proposal = _proposal(
        affinities: [RoleAffinity.provision],
        members: [_member('amenity=bench', RoleAffinity.provision)],
      );

      final node = provisionNodeFromProposal(proposal, id: 'n_new');

      expect(node, isNotNull);
      expect(node!.amenities, isEmpty);
      expect(node.kind, NodeKind.restStop);
    });

    test('a purely narrative cluster is not C5\'s to place — returns null', () {
      final proposal = _proposal(
        affinities: [RoleAffinity.narrative],
        members: [_member('tourism=viewpoint', RoleAffinity.narrative)],
      );

      expect(provisionNodeFromProposal(proposal, id: 'n_new'), isNull);
    });

    test('the kind is overridable — a proposal can be dropped as a regroup point instead', () {
      final proposal = _proposal(
        affinities: [RoleAffinity.provision],
        members: [_member('amenity=shelter', RoleAffinity.provision)],
      );

      final node = provisionNodeFromProposal(
        proposal,
        id: 'n_new',
        kind: NodeKind.regroup,
        distanceAlongM: 5400,
      );

      expect(node!.kind, NodeKind.regroup);
      expect(node.amenities, ['shelter']);
      expect(node.distanceAlongM, 5400);
    });
  });
}
