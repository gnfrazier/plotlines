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
}
