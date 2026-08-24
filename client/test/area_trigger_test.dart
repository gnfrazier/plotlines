// FR126 / O3 — "entry into a polygon anchor's boundary fires its narration,
// reveal, or notification the way point-proximity does for a point anchor,
// with entry debounced so a boundary-hugging route does not re-fire."
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

// A 1-degree square, well away from any rounding edge case; only inside/outside
// distinctions matter to these tests, not real-world scale.
final _square = Area(rings: [
  [
    [0.0, 0.0],
    [1.0, 0.0],
    [1.0, 1.0],
    [0.0, 1.0],
    [0.0, 0.0],
  ],
]);

const _inside = [0.5, 0.5];
const _outside = [5.0, 5.0];
// Straddle the eastern edge (x = 1.0) by a hair on either side — this is the
// GPS-wobble case ARCH §6.2 names, not a trip to the far side of the map.
const _justInside = [0.99, 0.5];
const _justOutside = [1.01, 0.5];

void main() {
  group('AreaEntryTrigger', () {
    test('fires exactly once on the sample that confirms entry', () {
      final trigger = AreaEntryTrigger(enterStreak: 3, exitStreak: 3);
      expect(trigger.update(_square, _inside), isFalse); // 1st inside sample
      expect(trigger.update(_square, _inside), isFalse); // 2nd
      expect(trigger.update(_square, _inside), isTrue); // 3rd — confirms entry
      expect(trigger.update(_square, _inside), isFalse); // already inside
      expect(trigger.update(_square, _inside), isFalse);
      expect(trigger.isInside, isTrue);
    });

    test('never fires while approaching but never completing the enter streak', () {
      final trigger = AreaEntryTrigger(enterStreak: 3, exitStreak: 3);
      for (var i = 0; i < 50; i++) {
        expect(trigger.update(_square, _outside), isFalse);
      }
      expect(trigger.isInside, isFalse);
    });

    test('a boundary-hugging route that wobbles in/out does not refire', () {
      // The exact failure ARCH §6.2 names: a route that runs along a park
      // edge would otherwise re-fire on every GPS wobble. Confirm entry
      // once, then wobble in/out without ever completing exitStreak.
      final trigger = AreaEntryTrigger(enterStreak: 3, exitStreak: 3);
      expect(trigger.update(_square, _inside), isFalse);
      expect(trigger.update(_square, _inside), isFalse);
      expect(trigger.update(_square, _inside), isTrue); // confirmed entry

      var fired = false;
      for (var i = 0; i < 30; i++) {
        // Alternates every sample, so neither 3 consecutive outside (which
        // would re-arm the trigger) nor 3 consecutive inside ever completes.
        final sample = i.isEven ? _justOutside : _justInside;
        if (trigger.update(_square, sample)) fired = true;
      }
      expect(fired, isFalse, reason: 'a boundary wobble must not re-fire the trigger');
      expect(trigger.isInside, isTrue, reason: 'a wobble that never completes exitStreak must not exit either');
    });

    test('exiting for a full exitStreak re-arms the trigger for a later entry', () {
      final trigger = AreaEntryTrigger(enterStreak: 2, exitStreak: 2);
      expect(trigger.update(_square, _inside), isFalse);
      expect(trigger.update(_square, _inside), isTrue); // first entry

      expect(trigger.update(_square, _outside), isFalse);
      expect(trigger.update(_square, _outside), isFalse); // confirms exit
      expect(trigger.isInside, isFalse);

      expect(trigger.update(_square, _inside), isFalse);
      expect(trigger.update(_square, _inside), isTrue); // second, distinct entry
    });

    test('a same-direction streak interrupted by one contrary sample restarts the count', () {
      final trigger = AreaEntryTrigger(enterStreak: 3, exitStreak: 3);
      expect(trigger.update(_square, _inside), isFalse); // streak = 1
      expect(trigger.update(_square, _inside), isFalse); // streak = 2
      expect(trigger.update(_square, _outside), isFalse); // resets inside streak
      expect(trigger.update(_square, _inside), isFalse); // streak = 1 again
      expect(trigger.update(_square, _inside), isFalse); // streak = 2
      expect(trigger.update(_square, _inside), isTrue); // streak = 3 — fires
    });

    test('reset() returns the tracker to never-entered', () {
      final trigger = AreaEntryTrigger(enterStreak: 1, exitStreak: 1);
      expect(trigger.update(_square, _inside), isTrue);
      expect(trigger.isInside, isTrue);

      trigger.reset();
      expect(trigger.isInside, isFalse);
      expect(trigger.update(_square, _inside), isTrue); // fires again, as a fresh entry
    });

    test('a single-sample enterStreak of 1 fires on the very first inside sample', () {
      final trigger = AreaEntryTrigger(enterStreak: 1, exitStreak: 1);
      expect(trigger.update(_square, _inside), isTrue);
    });
  });
}
