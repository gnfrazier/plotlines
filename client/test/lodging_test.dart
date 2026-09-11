// Story C7 (issue #43), FR23 — the pure-domain half: tag→type mapping and
// candidate→node conversion. Mirrors `core/tests/test_curation_taxonomy.py`'s
// coverage of the same five `tourism=*` tags on the core side.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/domain/domain.dart';

Candidate _candidate({String? tourism, String title = 'Some place'}) => Candidate(
      id: 'c1',
      coord: const [-105.27, 40.02],
      layer: 'amenity',
      salience: 0.5,
      roleAffinity: RoleAffinity.station,
      title: title,
      tags: tourism == null ? const {} : {'tourism': tourism},
    );

void main() {
  group('lodgingTypeForTags', () {
    test('maps each of the five OSM lodging tags to its type', () {
      expect(lodgingTypeForTags({'tourism': 'hotel'}), LodgingType.hotel);
      expect(lodgingTypeForTags({'tourism': 'hostel'}), LodgingType.hostel);
      expect(lodgingTypeForTags({'tourism': 'camp_site'}), LodgingType.campsite);
      expect(lodgingTypeForTags({'tourism': 'alpine_hut'}), LodgingType.hut);
      expect(lodgingTypeForTags({'tourism': 'wilderness_hut'}), LodgingType.hut);
    });

    test('a non-lodging or absent tourism tag maps to null', () {
      expect(lodgingTypeForTags({'tourism': 'viewpoint'}), isNull);
      expect(lodgingTypeForTags({'amenity': 'cafe'}), isNull);
      expect(lodgingTypeForTags(const {}), isNull);
    });
  });

  group('lodgingTypeOfCandidate', () {
    test('reads the candidate\'s own tags', () {
      expect(lodgingTypeOfCandidate(_candidate(tourism: 'camp_site')), LodgingType.campsite);
      expect(lodgingTypeOfCandidate(_candidate()), isNull);
    });
  });

  group('LodgingType', () {
    test('wireValue is the stored/poiType string for every type', () {
      expect(LodgingType.campsite.wireValue, 'campsite');
      expect(LodgingType.hotel.wireValue, 'hotel');
      expect(LodgingType.hut.wireValue, 'hut');
      expect(LodgingType.hostel.wireValue, 'hostel');
    });

    test('label is a distinct human string for every type', () {
      final labels = LodgingType.values.map((t) => t.label).toSet();
      expect(labels, hasLength(LodgingType.values.length));
    });
  });

  group('lodgingNodeFromCandidate', () {
    test('a lodging candidate becomes a POI node carrying the specific type', () {
      final node = lodgingNodeFromCandidate(
        _candidate(tourism: 'hotel', title: 'Grand Hotel'),
        id: 'n1',
      );
      expect(node, isNotNull);
      expect(node!.id, 'n1');
      expect(node.kind, NodeKind.poi);
      expect(node.coord, const [-105.27, 40.02]);
      expect(node.title, 'Grand Hotel');
      // The specific lodging type, never the bare "amenity" layer id — FR23's
      // "filter by type" only means something downstream if the placed node
      // still remembers which type it was.
      expect(node.poiType, 'hotel');
    });

    test('a non-lodging candidate produces no node', () {
      expect(lodgingNodeFromCandidate(_candidate(), id: 'n1'), isNull);
    });
  });

  group('isLodgingNode', () {
    test('true for a node whose poiType is a lodging wire value', () {
      final node = Node(id: 'n1', kind: NodeKind.poi, coord: const [0, 0], poiType: 'campsite');
      expect(isLodgingNode(node), isTrue);
    });

    test('false for a node with no poiType, or a non-lodging one', () {
      expect(isLodgingNode(Node(id: 'n1', kind: NodeKind.poi, coord: const [0, 0])), isFalse);
      expect(
        isLodgingNode(Node(id: 'n1', kind: NodeKind.poi, coord: const [0, 0], poiType: 'historic')),
        isFalse,
      );
    });
  });
}
