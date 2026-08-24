// P11 (ARCH §2, §7.8) — the single reveal gate. Every one of these assertions
// is checking a spoiler boundary: an on-arrival role must never surface its
// content before [hasArrived] is true, and hazard/provision content that is
// always-visible must never be blocked.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/reveal_resolver.dart';
import 'package:plotlines_client/domain/domain.dart';

void main() {
  const resolver = RevealResolver();

  group('RevealResolver.resolve', () {
    test('always_visible content is visible before arrival', () {
      final role = Role(id: 'r1', kind: RoleKind.provision, reveal: RevealPolicy.alwaysVisible, note: 'Water here.');
      final resolved = resolver.resolve(role, hasArrived: false);
      expect(resolved.visible, isTrue);
      expect(resolved.note, 'Water here.');
    });

    test('on_arrival content is withheld before arrival', () {
      final role = Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, note: 'The statue.');
      final resolved = resolver.resolve(role, hasArrived: false);
      expect(resolved.visible, isFalse);
      expect(resolved.note, isNull);
      expect(resolved.title, isNull);
      expect(resolved.media, isEmpty);
    });

    test('on_arrival content is visible after arrival', () {
      final role = Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, note: 'The statue.');
      final resolved = resolver.resolve(role, hasArrived: true);
      expect(resolved.visible, isTrue);
      expect(resolved.note, 'The statue.');
    });

    test('a role with no reveal policy set is withheld, never leaked by default', () {
      final role = Role(id: 'r1', kind: RoleKind.station, note: 'Undecided.');
      expect(resolver.resolve(role, hasArrived: false).visible, isFalse);
      expect(resolver.resolve(role, hasArrived: true).visible, isFalse);
    });
  });

  group('RevealResolver — role geometry (FR107 / O2)', () {
    test('a role with its own offset resolves to that offset, not the anchor coord', () {
      final role = Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, coord: [-105.266, 40.024]);
      final resolved = resolver.resolve(role, hasArrived: false, anchorCoord: [-105.27, 40.02]);
      expect(resolved.coord, [-105.266, 40.024]);
    });

    test('a role with no offset falls back to the anchor coord', () {
      final role = Role(id: 'r1', kind: RoleKind.narrative);
      final resolved = resolver.resolve(role, hasArrived: false, anchorCoord: [-105.27, 40.02]);
      expect(resolved.coord, [-105.27, 40.02]);
    });

    test('geometry resolves independently of reveal state — a withheld role still has a position', () {
      final role = Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, coord: [1.0, 2.0]);
      final resolved = resolver.resolve(role, hasArrived: false, anchorCoord: [0.0, 0.0]);
      expect(resolved.visible, isFalse);
      expect(resolved.coord, [1.0, 2.0]);
    });
  });

  group('RevealResolver.resolveAnchor', () {
    test('national monument: provision visible pre-trip, narrative withheld until arrival', () {
      final anchor = Anchor(
        id: 'a1',
        coord: [0.0, 0.0],
        roles: [
          Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, note: 'The statue.'),
          Role(id: 'r2', kind: RoleKind.provision, reveal: RevealPolicy.alwaysVisible, note: 'Restrooms, water.'),
        ],
      );
      final resolved = resolver.resolveAnchor(anchor, hasArrived: false);
      final narrative = resolved.firstWhere((r) => r.kind == RoleKind.narrative);
      final provision = resolved.firstWhere((r) => r.kind == RoleKind.provision);
      expect(narrative.visible, isFalse);
      expect(provision.visible, isTrue);
      expect(provision.note, 'Restrooms, water.');
    });

    test('the overlook spur: the narrative role resolves 400 m from the parking-lot anchor', () {
      // FR107 / O2's worked case, verbatim: "the overlook 400 m up the spur
      // from the parking lot ... a trigger measured from the wrong point
      // fires the narration in the wrong place."
      final parkingLot = [-105.270, 40.020];
      final overlook = [-105.266, 40.024];
      final anchor = Anchor(
        id: 'a1',
        coord: parkingLot,
        roles: [
          Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, coord: overlook),
        ],
      );
      final resolved = resolver.resolveAnchor(anchor, hasArrived: true);
      expect(resolved.single.coord, overlook);
      expect(resolved.single.coord, isNot(parkingLot));
    });
  });
}
