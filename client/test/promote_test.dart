// FR106, FR110 (Story O1) — the promotion interaction as a pure function:
// candidate -> anchor, with the affinity pre-fill and the "one anchor per
// place" duplicate check.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/promote.dart';

Candidate _candidate({String id = 'cand-1', RoleAffinity affinity = RoleAffinity.narrative}) =>
    Candidate(
      id: id,
      coord: [-105.27, 40.02],
      layer: 'historic',
      salience: 0.9,
      roleAffinity: affinity,
      title: 'Old Fort',
      tags: const {'historic': 'fort'},
    );

void main() {
  group('roleKindFromAffinity', () {
    test('maps each affinity to the matching role kind', () {
      expect(roleKindFromAffinity(RoleAffinity.narrative), RoleKind.narrative);
      expect(roleKindFromAffinity(RoleAffinity.provision), RoleKind.provision);
      expect(roleKindFromAffinity(RoleAffinity.station), RoleKind.station);
    });
  });

  group('provenanceFromCandidate', () {
    test('copies geometry-adjacent fields, never a live reference', () {
      final provenance = provenanceFromCandidate(_candidate());
      expect(provenance.kind, AnchorSourceKind.candidate);
      expect(provenance.sourceId, 'cand-1');
      expect(provenance.layer, 'historic');
      expect(provenance.tags['historic'], 'fort');
    });
  });

  group('promoteAnchor', () {
    test('promotes a bare candidate into a one-role anchor', () {
      final candidate = _candidate();
      final anchor = promoteAnchor(
        existingAnchors: const [],
        id: 'a1',
        coord: candidate.coord,
        title: candidate.title,
        roles: [Role(id: 'r1', kind: roleKindFromAffinity(candidate.roleAffinity))],
        provenance: provenanceFromCandidate(candidate),
      );
      expect(anchor.id, 'a1');
      expect(anchor.roles.single.kind, RoleKind.narrative);
      expect(anchor.provenance!.sourceId, 'cand-1');
    });

    test('promotes a hand-placed point with no candidate provenance', () {
      final anchor = promoteAnchor(
        existingAnchors: const [],
        id: 'a1',
        coord: const [-105.0, 40.0],
        title: 'Trailhead',
        roles: [Role(id: 'r1', kind: RoleKind.provision)],
        provenance: const AnchorProvenance(kind: AnchorSourceKind.handPlaced),
      );
      expect(anchor.provenance!.kind, AnchorSourceKind.handPlaced);
      expect(anchor.provenance!.sourceId, isNull);
    });

    test('national monument: assigning narrative + provision in one call', () {
      final anchor = promoteAnchor(
        existingAnchors: const [],
        id: 'a1',
        coord: const [-105.27, 40.02],
        roles: [
          Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival),
          Role(id: 'r2', kind: RoleKind.provision, reveal: RevealPolicy.alwaysVisible),
        ],
      );
      expect(anchor.roles.length, 2);
      expect(anchor.hasRole(RoleKind.narrative), isTrue);
      expect(anchor.hasRole(RoleKind.provision), isTrue);
    });

    test('re-promoting an already-promoted candidate throws rather than duplicating the pin', () {
      final candidate = _candidate();
      final first = promoteAnchor(
        existingAnchors: const [],
        id: 'a1',
        coord: candidate.coord,
        roles: [Role(id: 'r1', kind: RoleKind.narrative)],
        provenance: provenanceFromCandidate(candidate),
      );
      expect(
        () => promoteAnchor(
          existingAnchors: [first],
          id: 'a2',
          coord: candidate.coord,
          roles: [Role(id: 'r2', kind: RoleKind.provision)],
          provenance: provenanceFromCandidate(candidate),
        ),
        throwsA(isA<DuplicatePromotionException>()),
      );
    });

    test('two different candidates promote to two distinct anchors', () {
      final a = promoteAnchor(
        existingAnchors: const [],
        id: 'a1',
        coord: const [0.0, 0.0],
        roles: [Role(id: 'r1', kind: RoleKind.narrative)],
        provenance: provenanceFromCandidate(_candidate(id: 'cand-1')),
      );
      final b = promoteAnchor(
        existingAnchors: [a],
        id: 'a2',
        coord: const [1.0, 1.0],
        roles: [Role(id: 'r2', kind: RoleKind.station)],
        provenance: provenanceFromCandidate(_candidate(id: 'cand-2')),
      );
      expect(b.id, isNot(a.id));
    });

    test('area geometry passes through to the promoted anchor (FR108 / O3)', () {
      // A source feature's own polygon, adopted rather than drawn — the
      // "adopted from a source feature's own area geometry" half of FR108's
      // AC, which needs no special handling beyond threading `area` through.
      final area = Area(rings: [
        [
          [-105.28, 40.01],
          [-105.27, 40.01],
          [-105.27, 40.02],
          [-105.28, 40.02],
          [-105.28, 40.01],
        ]
      ]);
      final candidate = _candidate();
      final anchor = promoteAnchor(
        existingAnchors: const [],
        id: 'a1',
        coord: candidate.coord,
        title: candidate.title,
        area: area,
        roles: [Role(id: 'r1', kind: roleKindFromAffinity(candidate.roleAffinity))],
        provenance: provenanceFromCandidate(candidate),
      );
      expect(anchor.area, area);
      expect(anchor.containsPoint([-105.275, 40.015]), isTrue);
    });

    test('areaFromCandidate adopts a polygon candidate\'s ring as an imported Area (#403)', () {
      // The path SPIKE-H §3 found missing, at its last link: the ring that
      // rode `/candidates` becomes the anchor's own `area`, marked
      // `imported` so the payload records it was adopted rather than drawn.
      const ring = [
        [-105.28, 40.01],
        [-105.27, 40.01],
        [-105.27, 40.02],
        [-105.28, 40.02],
        [-105.28, 40.01],
      ];
      final candidate = Candidate(
        id: 'w1',
        coord: [-105.275, 40.015],
        layer: 'leisure',
        salience: 0.7,
        roleAffinity: RoleAffinity.station,
        areaM2: 12000.0,
        geometry: const CandidatePolygon(ring: ring),
      );
      final area = areaFromCandidate(candidate);
      expect(area, isNotNull);
      expect(area!.source, AreaSource.imported);
      expect(area.rings, [ring]);
      // Copied, not referenced (§4.2 / P10): the anchor's ring is its own.
      expect(identical(area.rings.first, ring), isFalse);

      final anchor = promoteAnchor(
        existingAnchors: const [],
        id: 'a1',
        coord: candidate.coord,
        area: area,
        roles: [Role(id: 'r1', kind: roleKindFromAffinity(candidate.roleAffinity))],
        provenance: provenanceFromCandidate(candidate),
      );
      expect(anchor.containsPoint([-105.275, 40.015]), isTrue);
      expect(anchor.toJson()['area']['source'], 'imported');
    });

    test('areaFromCandidate is null for a point and for a line candidate', () {
      expect(areaFromCandidate(_candidate()), isNull);
      final byway = Candidate(
        id: 'byway/1',
        coord: [0.05, 0.02],
        layer: 'byways',
        salience: 0.7,
        roleAffinity: RoleAffinity.narrative,
        geometry: const CandidateLine(coords: [
          [0.0, 0.0],
          [0.05, 0.02],
          [0.1, 0.0],
        ]),
      );
      // An anchor is a point or a polygon; a path is passage-shaped. Never
      // close a byway into an area it never was.
      expect(areaFromCandidate(byway), isNull);
    });

    test('promoting with no area leaves the anchor a plain point (O2\'s AC extended)', () {
      final anchor = promoteAnchor(
        existingAnchors: const [],
        id: 'a1',
        coord: const [0.0, 0.0],
        roles: [Role(id: 'r1', kind: RoleKind.narrative)],
      );
      expect(anchor.area, isNull);
    });

    test('hand-placed anchors carry no source id, so nothing dedups them', () {
      final a = promoteAnchor(
        existingAnchors: const [],
        id: 'a1',
        coord: const [0.0, 0.0],
        roles: [Role(id: 'r1', kind: RoleKind.narrative)],
        provenance: const AnchorProvenance(kind: AnchorSourceKind.handPlaced),
      );
      final b = promoteAnchor(
        existingAnchors: [a],
        id: 'a2',
        coord: const [0.0, 0.0],
        roles: [Role(id: 'r2', kind: RoleKind.narrative)],
        provenance: const AnchorProvenance(kind: AnchorSourceKind.handPlaced),
      );
      expect(b.id, isNot(a.id));
    });
  });
}
