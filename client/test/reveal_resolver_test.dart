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

  // FR114 / O5 — provision defaults to always-visible; narrative/station have
  // no engine default ("the Author's choice"), so they stay withheld.
  group('RevealResolver.effectivePolicy — FR114 defaults', () {
    test('an undecided provision role defaults to always-visible', () {
      final role = Role(id: 'r1', kind: RoleKind.provision, note: 'Water here.');
      expect(resolver.effectivePolicy(role), RevealPolicy.alwaysVisible);
      final resolved = resolver.resolve(role, hasArrived: false);
      expect(resolved.visible, isTrue);
      expect(resolved.note, 'Water here.');
      expect(resolved.state, RevealState.alwaysVisible);
    });

    test('an undecided narrative role has no engine default and stays withheld', () {
      final role = Role(id: 'r1', kind: RoleKind.narrative, note: 'The statue.');
      expect(resolver.effectivePolicy(role), isNull);
      expect(resolver.resolve(role, hasArrived: false).state, RevealState.withheld);
    });

    test('an undecided station role has no engine default and stays withheld', () {
      final role = Role(id: 'r1', kind: RoleKind.station, note: 'The crag.');
      expect(resolver.effectivePolicy(role), isNull);
      expect(resolver.resolve(role, hasArrived: false).state, RevealState.withheld);
    });

    test('an Author can still explicitly set a provision role on_arrival — the default yields to an explicit choice', () {
      final role = Role(id: 'r1', kind: RoleKind.provision, reveal: RevealPolicy.onArrival, note: 'Hidden spring.');
      expect(resolver.effectivePolicy(role), RevealPolicy.onArrival);
      expect(resolver.resolve(role, hasArrived: false).visible, isFalse);
      expect(resolver.resolve(role, hasArrived: true).visible, isTrue);
    });
  });

  // FR115 / O5 — the hard constraint: a hazard/technical-crux role is always
  // visible, regardless of role kind, its own `reveal`, or an Author's intent.
  group('RevealResolver.effectivePolicy — FR115 hazard exemption', () {
    test('a hazard role with no reveal set resolves always-visible, not withheld', () {
      final role = Role(id: 'r1', kind: RoleKind.narrative, hazard: true, note: 'Strainer ahead.');
      expect(resolver.effectivePolicy(role), RevealPolicy.alwaysVisible);
      final resolved = resolver.resolve(role, hasArrived: false);
      expect(resolved.visible, isTrue);
      expect(resolved.state, RevealState.alwaysVisible);
      expect(resolved.note, 'Strainer ahead.');
    });

    test('a hazard station role is visible before arrival, same as any other hazard', () {
      final role = Role(id: 'r1', kind: RoleKind.station, hazard: true, note: 'Mandatory portage.');
      expect(resolver.resolve(role, hasArrived: false).visible, isTrue);
    });

    test('constructing a hazard role as on_arrival is rejected outright — FR115 is unrepresentable, not just unresolved', () {
      expect(
        () => Role(id: 'r1', kind: RoleKind.narrative, hazard: true, reveal: RevealPolicy.onArrival),
        throwsArgumentError,
      );
    });

    test('a hazard role explicitly marked always_visible round-trips as always-visible (the only representable combination)', () {
      final role = Role(id: 'r1', kind: RoleKind.provision, hazard: true, reveal: RevealPolicy.alwaysVisible);
      expect(resolver.resolve(role, hasArrived: false).visible, isTrue);
    });
  });

  // O5's AC — "the Author can preview the trip as a Character would see it
  // before departure": `hasArrived: false` across the whole anchor is that
  // preview, mixing always-visible/default/hazard content with withheld
  // narrative — the exact national-monument-plus-hazard shape the preview
  // has to get right.
  group('RevealResolver — Author preview before departure (O5 AC)', () {
    test('an undecided provision role and a hazard role both show through the pre-departure preview, an undecided narrative role does not', () {
      final anchor = Anchor(
        id: 'a1',
        coord: [0.0, 0.0],
        roles: [
          Role(id: 'r1', kind: RoleKind.narrative, note: 'The waterfall.'),
          Role(id: 'r2', kind: RoleKind.provision, note: 'Water here.'),
          Role(id: 'r3', kind: RoleKind.station, hazard: true, note: 'Exposed scramble.'),
        ],
      );
      final preview = resolver.resolveAnchor(anchor, hasArrived: false);
      final byId = {for (final r in preview) r.roleId: r};
      expect(byId['r1']!.visible, isFalse);
      expect(byId['r2']!.visible, isTrue);
      expect(byId['r3']!.visible, isTrue);
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
