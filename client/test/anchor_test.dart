// FR106, FR110 (Story O1) — Anchor/Role wire parsing and the role-set
// invariant that makes the national-monument case one anchor, not two.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  group('Anchor', () {
    test('an anchor requires at least one role', () {
      expect(
        () => Anchor(id: 'a1', coord: [0.0, 0.0], roles: const []),
        throwsArgumentError,
      );
    });

    test('national monument: one anchor, narrative + provision, one pin', () {
      final anchor = Anchor(
        id: 'a1',
        coord: [-105.27, 40.02],
        title: 'Independence Monument',
        roles: [
          Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival),
          Role(id: 'r2', kind: RoleKind.provision, reveal: RevealPolicy.alwaysVisible),
        ],
      );
      expect(anchor.roles.length, 2);
      expect(anchor.hasRole(RoleKind.narrative), isTrue);
      expect(anchor.hasRole(RoleKind.provision), isTrue);
      expect(anchor.hasRole(RoleKind.station), isFalse);
      // One id, one coord — one arrival, one pin — regardless of role count.
      expect(anchor.id, 'a1');
    });

    test('round-trips through JSON', () {
      final anchor = Anchor(
        id: 'a1',
        coord: [-105.27, 40.02],
        title: 'Old Fort',
        roles: [Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, note: 'The story.')],
        provenance: const AnchorProvenance(
          kind: AnchorSourceKind.candidate,
          sourceId: 'cand-1',
          layer: 'historic',
          tags: {'historic': 'fort'},
        ),
      );
      final decoded = Anchor.fromJson(anchor.toJson());
      expect(decoded.id, anchor.id);
      expect(decoded.coord, anchor.coord);
      expect(decoded.title, anchor.title);
      expect(decoded.roles.single.kind, RoleKind.narrative);
      expect(decoded.roles.single.reveal, RevealPolicy.onArrival);
      expect(decoded.roles.single.note, 'The story.');
      expect(decoded.provenance!.sourceId, 'cand-1');
      expect(decoded.provenance!.tags['historic'], 'fort');
    });

    test('reveal and content may be absent — set here or later', () {
      final anchor = Anchor(id: 'a1', coord: [0.0, 0.0], roles: [Role(id: 'r1', kind: RoleKind.station)]);
      final json = anchor.toJson();
      final role = (json['roles'] as List).single as Map<String, dynamic>;
      expect(role.containsKey('reveal'), isFalse);
      expect(role.containsKey('title'), isFalse);
      expect(role.containsKey('note'), isFalse);
    });

    test('an unknown role_kind on read throws rather than silently dropping', () {
      expect(
        () => Role.fromJson({'id': 'r1', 'kind': 'scenic'}),
        throwsFormatException,
      );
    });

    test('an unknown reveal_policy on read throws rather than silently dropping', () {
      expect(
        () => Role.fromJson({'id': 'r1', 'kind': 'narrative', 'reveal': 'sometimes'}),
        throwsFormatException,
      );
    });
  });

  group('Role.coord (FR107 / O2)', () {
    test('an anchor with no role offsets: every role resolves to the anchor coord', () {
      final anchor = Anchor(
        id: 'a1',
        coord: [-105.27, 40.02],
        roles: [
          Role(id: 'r1', kind: RoleKind.narrative),
          Role(id: 'r2', kind: RoleKind.provision),
        ],
      );
      for (final role in anchor.roles) {
        expect(anchor.roleGeometry(role), anchor.coord);
      }
    });

    test('the overlook spur: a role offset resolves to its own coord, not the anchor\'s', () {
      // FR107's worked case: parking-lot anchor, narrative role 400 m up a spur.
      final overlook = Role(id: 'r1', kind: RoleKind.narrative, coord: [-105.266, 40.024]);
      final anchor = Anchor(id: 'a1', coord: [-105.27, 40.02], roles: [overlook]);
      expect(anchor.roleGeometry(overlook), [-105.266, 40.024]);
    });

    test('role coord round-trips through JSON', () {
      final role = Role(id: 'r1', kind: RoleKind.narrative, coord: [-105.266, 40.024]);
      final decoded = Role.fromJson(role.toJson());
      expect(decoded.coord, [-105.266, 40.024]);
    });

    test('an unset role coord is absent from JSON, not written as null', () {
      final role = Role(id: 'r1', kind: RoleKind.narrative);
      expect(role.toJson().containsKey('coord'), isFalse);
      expect(Role.fromJson(role.toJson()).coord, isNull);
    });

    test('copyWith preserves coord by default and clears it via clearCoord', () {
      final role = Role(id: 'r1', kind: RoleKind.narrative, coord: [1.0, 2.0]);
      expect(role.copyWith(title: 'x').coord, [1.0, 2.0]);
      expect(role.copyWith(clearCoord: true).coord, isNull);
    });
  });

  group('Trip.anchors', () {
    test('round-trips and is absent when empty', () {
      final empty = Trip(id: 't1', title: 'Empty', createdAt: 'x', updatedAt: 'x');
      expect(empty.toJson().containsKey('anchors'), isFalse);

      final trip = Trip(
        id: 't1',
        title: 'Has anchors',
        createdAt: 'x',
        updatedAt: 'x',
        anchors: [Anchor(id: 'a1', coord: [0.0, 0.0], roles: [Role(id: 'r1', kind: RoleKind.narrative)])],
      );
      final decoded = Trip.fromJson(trip.toJson());
      expect(decoded.anchors.single.id, 'a1');
      expect(decoded.anchors.single.roles.single.kind, RoleKind.narrative);
    });
  });

  // FR108, FR126 / O3 — polygon area geometry.
  group('Anchor.area (FR108 / O3)', () {
    // Closed square ring, wound counter-clockwise (canonical exterior winding).
    const squareCcw = [
      [-105.28, 40.01],
      [-105.27, 40.01],
      [-105.27, 40.02],
      [-105.28, 40.02],
      [-105.28, 40.01],
    ];

    test('an anchor with no area omits it and contains nothing', () {
      final anchor = Anchor(id: 'a1', coord: [0.0, 0.0], roles: [Role(id: 'r1', kind: RoleKind.narrative)]);
      expect(anchor.toJson().containsKey('area'), isFalse);
      expect(anchor.containsPoint([0.0, 0.0]), isFalse);
    });

    test('anchor area round-trips through JSON', () {
      final anchor = Anchor(
        id: 'a1',
        coord: [-105.275, 40.015],
        area: Area(rings: [squareCcw]),
        roles: [Role(id: 'r1', kind: RoleKind.narrative)],
      );
      final decoded = Anchor.fromJson(anchor.toJson());
      expect(decoded.area, isNotNull);
      expect(decoded.area!.rings.single, squareCcw);
      expect(decoded.area!.source, AreaSource.authored);
    });

    test('a ring must be closed', () {
      final open = squareCcw.sublist(0, 4); // drops the closing repeat
      expect(() => Area(rings: [open]).toJson(), throwsFormatException);
    });

    test('a ring needs at least 4 positions', () {
      expect(
        () => Area(rings: [
          [
            [0.0, 0.0],
            [1.0, 0.0],
            [0.0, 0.0],
          ]
        ]).toJson(),
        throwsFormatException,
      );
    });

    test('a clockwise exterior ring is normalised to canonical CCW, not rejected', () {
      final clockwise = squareCcw.reversed.toList();
      final out = Area(rings: [clockwise]).toJson();
      expect(out['coordinates'], [squareCcw]);
    });

    test('containsPoint is true inside and false outside the boundary', () {
      final area = Area(rings: [squareCcw]);
      expect(area.containsPoint([-105.275, 40.015]), isTrue);
      expect(area.containsPoint([-105.29, 40.015]), isFalse);
    });

    test('containsPoint excludes a hole', () {
      const outer = [
        [-105.30, 40.00],
        [-105.20, 40.00],
        [-105.20, 40.10],
        [-105.30, 40.10],
        [-105.30, 40.00],
      ];
      const hole = [
        [-105.27, 40.03],
        [-105.23, 40.03],
        [-105.23, 40.07],
        [-105.27, 40.07],
        [-105.27, 40.03],
      ];
      final donut = Area(rings: [outer, hole]);
      expect(donut.containsPoint([-105.29, 40.01]), isTrue);
      expect(donut.containsPoint([-105.25, 40.05]), isFalse);
    });

    test('an area serves as a cluster boundary instead of point-plus-radius', () {
      // The anchor's own coord sits near one corner; a point near the
      // opposite corner — well past any sane point-radius — is still "in."
      final anchor = Anchor(
        id: 'a1',
        coord: [-105.2799, 40.0101],
        area: Area(rings: [squareCcw]),
        roles: [Role(id: 'r1', kind: RoleKind.narrative)],
      );
      expect(anchor.containsPoint([-105.271, 40.019]), isTrue);
    });

    test('roleArea falls back from the role to the anchor to null', () {
      final anchorArea = Area(rings: [squareCcw]);
      final roleArea = Area(rings: [
        [
          [1.0, 1.0],
          [2.0, 1.0],
          [2.0, 2.0],
          [1.0, 2.0],
          [1.0, 1.0],
        ]
      ]);
      final withOwnArea = Role(id: 'r1', kind: RoleKind.provision, area: roleArea);
      final withoutOwnArea = Role(id: 'r2', kind: RoleKind.narrative);
      final anchor = Anchor(id: 'a1', coord: [0.0, 0.0], area: anchorArea, roles: [withOwnArea, withoutOwnArea]);

      expect(anchor.roleArea(withOwnArea), roleArea);
      expect(anchor.roleArea(withoutOwnArea), anchorArea);

      final pointOnlyAnchor = Anchor(id: 'a2', coord: [0.0, 0.0], roles: [Role(id: 'r3', kind: RoleKind.narrative)]);
      expect(pointOnlyAnchor.roleArea(pointOnlyAnchor.roles.single), isNull);
    });
  });
}
