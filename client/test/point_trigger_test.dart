// FR41, FR124, FR126 / P1 — the point-role counterpart to
// area_trigger_test.dart's [AreaEntryTrigger] coverage: entry into a
// radius around a point role fires exactly once, debounced the same way.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

// A point near (but not at) the origin, and a radius small enough that
// nearby-but-outside coordinates are unambiguous. Coordinates here are
// synthetic (not real-world scale) — only the haversine distance relative
// to [_radiusM] matters to these tests.
const _center = [-105.270, 40.020];
const _radiusM = 100.0;
const _insidePoint = [-105.270, 40.0205]; // ~55 m north — inside
const _outsidePoint = [-105.270, 40.030]; // ~1.1 km north — well outside

void main() {
  group('PointEntryTrigger', () {
    test('fires exactly once on the sample that confirms entry', () {
      final trigger = PointEntryTrigger(enterStreak: 3, exitStreak: 3);
      expect(trigger.update(_center, _radiusM, _insidePoint), isFalse);
      expect(trigger.update(_center, _radiusM, _insidePoint), isFalse);
      expect(trigger.update(_center, _radiusM, _insidePoint), isTrue);
      expect(trigger.update(_center, _radiusM, _insidePoint), isFalse);
      expect(trigger.isInside, isTrue);
    });

    test('never fires while position stays outside the radius', () {
      final trigger = PointEntryTrigger(enterStreak: 3, exitStreak: 3);
      for (var i = 0; i < 20; i++) {
        expect(trigger.update(_center, _radiusM, _outsidePoint), isFalse);
      }
      expect(trigger.isInside, isFalse);
    });

    test('a same-direction streak interrupted by one contrary sample restarts the count', () {
      final trigger = PointEntryTrigger(enterStreak: 3, exitStreak: 3);
      expect(trigger.update(_center, _radiusM, _insidePoint), isFalse); // 1
      expect(trigger.update(_center, _radiusM, _insidePoint), isFalse); // 2
      expect(trigger.update(_center, _radiusM, _outsidePoint), isFalse); // resets
      expect(trigger.update(_center, _radiusM, _insidePoint), isFalse); // 1
      expect(trigger.update(_center, _radiusM, _insidePoint), isFalse); // 2
      expect(trigger.update(_center, _radiusM, _insidePoint), isTrue); // 3 — fires
    });

    test('exiting for a full exitStreak re-arms the trigger for a later entry', () {
      final trigger = PointEntryTrigger(enterStreak: 2, exitStreak: 2);
      expect(trigger.update(_center, _radiusM, _insidePoint), isFalse);
      expect(trigger.update(_center, _radiusM, _insidePoint), isTrue); // first entry

      expect(trigger.update(_center, _radiusM, _outsidePoint), isFalse);
      expect(trigger.update(_center, _radiusM, _outsidePoint), isFalse); // confirms exit
      expect(trigger.isInside, isFalse);

      expect(trigger.update(_center, _radiusM, _insidePoint), isFalse);
      expect(trigger.update(_center, _radiusM, _insidePoint), isTrue); // second, distinct entry
    });

    test('reset() returns the tracker to never-entered', () {
      final trigger = PointEntryTrigger(enterStreak: 1, exitStreak: 1);
      expect(trigger.update(_center, _radiusM, _insidePoint), isTrue);
      expect(trigger.isInside, isTrue);

      trigger.reset();
      expect(trigger.isInside, isFalse);
      expect(trigger.update(_center, _radiusM, _insidePoint), isTrue); // fires again
    });

    test('a single-sample enterStreak of 1 fires on the very first inside sample', () {
      final trigger = PointEntryTrigger(enterStreak: 1, exitStreak: 1);
      expect(trigger.update(_center, _radiusM, _insidePoint), isTrue);
    });

    test('a position exactly at the radius boundary counts as inside (<=, not <)', () {
      // (0, 0) to (0, r) along a meridian is exactly haversineM apart; walk
      // outward from center by other means is fragile, so this asserts the
      // boundary case directly against the center itself, which is always
      // inside regardless of radius.
      final trigger = PointEntryTrigger(enterStreak: 1, exitStreak: 1);
      expect(trigger.update(_center, 0.0, _center), isTrue);
    });
  });
}
