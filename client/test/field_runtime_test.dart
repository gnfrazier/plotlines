// FR124, FR114 / P1 — "Discover content by arriving." Each group below maps
// to one of the story's acceptance criteria:
//   AC1: withheld until the Character's position enters the trigger
//        distance or area boundary
//   AC2: unlocks permanently on arrival
//   AC3: runs fully offline from raw GPS, no connectivity
//   AC4: provisions and hazards are never withheld (O5)
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/field_runtime.dart';
import 'package:plotlines_client/domain/domain.dart';

const _radiusM = 50.0;
double _fixedRadius(Role role) => _radiusM;

void main() {
  group('FieldRuntime — AC1: withheld until the trigger fires (point roles)', () {
    test('an on_arrival narrative role is withheld before its trigger distance is reached', () {
      final anchor = Anchor(
        id: 'a1',
        coord: [-105.270, 40.020],
        roles: [Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, note: 'The waterfall.')],
      );
      final runtime = FieldRuntime(anchors: [anchor], pointTriggerDistanceM: _fixedRadius);

      // Far away — never within the trigger radius.
      for (var i = 0; i < 5; i++) {
        runtime.ingestPosition([-105.270, 40.500]);
      }
      expect(runtime.hasArrived('r1'), isFalse);
      final resolved = runtime.resolveRole(anchor.roles.single);
      expect(resolved.visible, isFalse);
      expect(resolved.note, isNull);
      // ARCH §6.7 — a withheld role is not an absent one: it still resolves
      // a position, so the pre-trip view can show "something is here".
      expect(resolved.coord, anchor.coord);
    });

    test('the role unlocks once the Character\'s position enters its trigger distance', () {
      final anchor = Anchor(
        id: 'a1',
        coord: [-105.270, 40.020],
        roles: [Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, note: 'The waterfall.')],
      );
      final runtime =
          FieldRuntime(anchors: [anchor], pointTriggerDistanceM: _fixedRadius, enterStreak: 1, exitStreak: 1);

      expect(runtime.ingestPosition([-105.270, 40.500]), isEmpty); // far away
      final fired = runtime.ingestPosition(anchor.coord); // right on top of it
      expect(fired, ['r1']);
      expect(runtime.hasArrived('r1'), isTrue);
      final resolved = runtime.resolveRole(anchor.roles.single);
      expect(resolved.visible, isTrue);
      expect(resolved.note, 'The waterfall.');
    });

    test('FR107 / O2 — the trigger fires from the role\'s own offset, not the anchor\'s coord', () {
      // The overlook-spur case: the anchor sits at the parking lot, but the
      // narrative role's own coord is 400 m up a spur. Standing at the
      // parking lot must not fire the trigger.
      final parkingLot = [-105.270, 40.020];
      final overlook = [-105.266, 40.024];
      final anchor = Anchor(
        id: 'a1',
        coord: parkingLot,
        roles: [Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, coord: overlook)],
      );
      final runtime =
          FieldRuntime(anchors: [anchor], pointTriggerDistanceM: _fixedRadius, enterStreak: 1, exitStreak: 1);

      expect(runtime.ingestPosition(parkingLot), isEmpty);
      expect(runtime.hasArrived('r1'), isFalse);

      final fired = runtime.ingestPosition(overlook);
      expect(fired, ['r1']);
    });
  });

  group('FieldRuntime — AC1: area roles fire on polygon entry (FR126)', () {
    test('an on_arrival station role withholds until the Character enters the anchor\'s polygon', () {
      final square = Area(rings: [
        [
          [0.0, 0.0],
          [1.0, 0.0],
          [1.0, 1.0],
          [0.0, 1.0],
          [0.0, 0.0],
        ],
      ]);
      final anchor = Anchor(
        id: 'a1',
        coord: [0.5, 0.5],
        area: square,
        roles: [Role(id: 'r1', kind: RoleKind.station, reveal: RevealPolicy.onArrival, note: 'Main Street.')],
      );
      final runtime =
          FieldRuntime(anchors: [anchor], pointTriggerDistanceM: _fixedRadius, enterStreak: 1, exitStreak: 1);

      expect(runtime.ingestPosition([5.0, 5.0]), isEmpty); // outside
      expect(runtime.hasArrived('r1'), isFalse);

      final fired = runtime.ingestPosition([0.5, 0.5]); // inside
      expect(fired, ['r1']);
      expect(runtime.resolveRole(anchor.roles.single).visible, isTrue);
    });

    test('a boundary-hugging wobble does not fire the reveal repeatedly', () {
      final square = Area(rings: [
        [
          [0.0, 0.0],
          [1.0, 0.0],
          [1.0, 1.0],
          [0.0, 1.0],
          [0.0, 0.0],
        ],
      ]);
      final anchor = Anchor(
        id: 'a1',
        coord: [0.5, 0.5],
        area: square,
        roles: [Role(id: 'r1', kind: RoleKind.station, reveal: RevealPolicy.onArrival)],
      );
      final runtime = FieldRuntime(anchors: [anchor], pointTriggerDistanceM: _fixedRadius);

      runtime.ingestPosition([0.5, 0.5]);
      runtime.ingestPosition([0.5, 0.5]);
      final fires = <String>[];
      fires.addAll(runtime.ingestPosition([0.5, 0.5])); // confirms entry (streak 3)
      for (var i = 0; i < 20; i++) {
        fires.addAll(runtime.ingestPosition(i.isEven ? [0.99, 0.5] : [1.01, 0.5]));
      }
      expect(fires, ['r1']); // fired exactly once, total
    });
  });

  group('FieldRuntime — AC2: reveal is permanent once fired', () {
    test('a role stays revealed even after the Character moves away again', () {
      final anchor = Anchor(
        id: 'a1',
        coord: [-105.270, 40.020],
        roles: [Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, note: 'The waterfall.')],
      );
      final runtime =
          FieldRuntime(anchors: [anchor], pointTriggerDistanceM: _fixedRadius, enterStreak: 1, exitStreak: 1);

      runtime.ingestPosition(anchor.coord);
      expect(runtime.hasArrived('r1'), isTrue);

      runtime.ingestPosition([-105.270, 41.000]); // far away again
      runtime.ingestPosition([-105.270, 41.000]);
      expect(runtime.hasArrived('r1'), isTrue, reason: 'FR124: unlocked permanently, no re-hiding');
      expect(runtime.resolveRole(anchor.roles.single).visible, isTrue);
    });

    test('initiallyRevealed seeds permanent state — a hydration seam for the persisted reveal log (P8)', () {
      final anchor = Anchor(
        id: 'a1',
        coord: [-105.270, 40.020],
        roles: [Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, note: 'The waterfall.')],
      );
      final runtime = FieldRuntime(
        anchors: [anchor],
        pointTriggerDistanceM: _fixedRadius,
        initiallyRevealed: {'r1'},
      );
      expect(runtime.hasArrived('r1'), isTrue);
      expect(runtime.resolveRole(anchor.roles.single).visible, isTrue);
      // Never fires again — already permanently revealed.
      expect(runtime.ingestPosition([0.0, 0.0]), isEmpty);
    });

    test('revealedRoleIds is a snapshot, not a live mutable view', () {
      final anchor = Anchor(
        id: 'a1',
        coord: [0.0, 0.0],
        roles: [Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival)],
      );
      final runtime = FieldRuntime(anchors: [anchor], pointTriggerDistanceM: _fixedRadius, enterStreak: 1);
      runtime.ingestPosition([0.0, 0.0]);
      final snapshot = runtime.revealedRoleIds;
      expect(snapshot, {'r1'});
      expect(() => snapshot.add('r2'), throwsUnsupportedError);
    });
  });

  group('FieldRuntime — AC3: runs fully offline from raw GPS', () {
    test('ingestPosition is a pure, synchronous function — no async I/O in the critical path', () {
      final anchor = Anchor(
        id: 'a1',
        coord: [0.0, 0.0],
        roles: [Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival)],
      );
      final runtime = FieldRuntime(anchors: [anchor], pointTriggerDistanceM: _fixedRadius, enterStreak: 1);
      // Calling and immediately reading the result with no await proves this
      // is not a Future-returning / network-backed call.
      final result = runtime.ingestPosition([0.0, 0.0]);
      expect(result, ['r1']);
      expect(runtime.hasArrived('r1'), isTrue);
    });
  });

  group('FieldRuntime — AC4: provisions and hazards are never withheld (O5)', () {
    test('an always-visible provision role never enters the trigger engine and reads visible from the start', () {
      final anchor = Anchor(
        id: 'a1',
        coord: [-105.270, 40.020],
        roles: [
          Role(id: 'r1', kind: RoleKind.provision, reveal: RevealPolicy.alwaysVisible, note: 'Water here.'),
        ],
      );
      final runtime = FieldRuntime(anchors: [anchor], pointTriggerDistanceM: _fixedRadius);
      // No position ever ingested — content is visible from the moment the
      // trip downloads, not gated behind any trigger.
      final resolved = runtime.resolveRole(anchor.roles.single);
      expect(resolved.visible, isTrue);
      expect(resolved.note, 'Water here.');
    });

    test('a hazard role is visible before any position update, regardless of geometry', () {
      final anchor = Anchor(
        id: 'a1',
        coord: [-105.270, 40.020],
        roles: [Role(id: 'r1', kind: RoleKind.station, hazard: true, note: 'Exposed scramble.')],
      );
      final runtime = FieldRuntime(anchors: [anchor], pointTriggerDistanceM: _fixedRadius);
      expect(runtime.resolveRole(anchor.roles.single).visible, isTrue);
    });

    test('the national monument: provision visible pre-trip, narrative withheld until arrival, on one anchor', () {
      final anchor = Anchor(
        id: 'a1',
        coord: [-105.270, 40.020],
        roles: [
          Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, note: 'The statue.'),
          Role(id: 'r2', kind: RoleKind.provision, reveal: RevealPolicy.alwaysVisible, note: 'Restrooms, water.'),
        ],
      );
      final runtime =
          FieldRuntime(anchors: [anchor], pointTriggerDistanceM: _fixedRadius, enterStreak: 1, exitStreak: 1);

      var resolved = {for (final r in runtime.resolveAnchor(anchor)) r.roleId: r};
      expect(resolved['r1']!.visible, isFalse);
      expect(resolved['r2']!.visible, isTrue);

      runtime.ingestPosition(anchor.coord);
      resolved = {for (final r in runtime.resolveAnchor(anchor)) r.roleId: r};
      expect(resolved['r1']!.visible, isTrue, reason: 'arrival unlocked the narrative role');
      expect(resolved['r2']!.visible, isTrue, reason: 'provision was never gated in the first place');
    });
  });

  group('FieldRuntime — per-role independence on a shared anchor (FR114)', () {
    test('two on_arrival roles on the same anchor with different geometry reveal independently', () {
      final parkingLot = [-105.270, 40.020];
      final overlook = [-105.266, 40.024];
      final anchor = Anchor(
        id: 'a1',
        coord: parkingLot,
        roles: [
          Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, coord: overlook, note: 'View.'),
          Role(id: 'r2', kind: RoleKind.station, reveal: RevealPolicy.onArrival, note: 'The trailhead register.'),
        ],
      );
      final runtime =
          FieldRuntime(anchors: [anchor], pointTriggerDistanceM: _fixedRadius, enterStreak: 1, exitStreak: 1);

      // Standing at the parking lot fires r2 (at the anchor coord) but not
      // r1 (400 m up the spur).
      final fired = runtime.ingestPosition(parkingLot);
      expect(fired, ['r2']);
      expect(runtime.hasArrived('r1'), isFalse);
      expect(runtime.hasArrived('r2'), isTrue);

      final firedNext = runtime.ingestPosition(overlook);
      expect(firedNext, ['r1']);
      expect(runtime.hasArrived('r1'), isTrue);
    });
  });
}
