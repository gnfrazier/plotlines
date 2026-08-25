// Story A8 (issue #25) — target distance is settable for loop/out-and-back
// only, and banded by default in explore mode (SPIKE-03: up to +14.8%
// unannounced drift when unbanded). Covers `planner_ui_state.dart`'s pure
// helpers: `hasTargetDistanceControl` (which shapes get the control at all)
// and `bandedTargetDistance` (the default band a fresh target gets).
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/state/planner_ui_state.dart';

void main() {
  group('hasTargetDistanceControl', () {
    test('loop and out_and_back get the control', () {
      expect(hasTargetDistanceControl('loop'), isTrue);
      expect(hasTargetDistanceControl('out_and_back'), isTrue);
    });

    test('point_to_point has no target-distance input', () {
      expect(hasTargetDistanceControl('point_to_point'), isFalse);
    });
  });

  group('bandedTargetDistance', () {
    test('bands the value symmetrically at the default fraction', () {
      final target = bandedTargetDistance(20000.0);
      expect(target.valueM, 20000.0);
      expect(target.minM, 18000.0);
      expect(target.maxM, 22000.0);
    });

    test('the default half-width catches SPIKE-03\'s own measured drift '
        '(+14.8% unbanded)', () {
      final target = bandedTargetDistance(20000.0);
      final drifted = 20000.0 * 1.148;
      expect(drifted > target.maxM!, isTrue);
    });

    test('a wider explicit fraction bands more loosely', () {
      final target = bandedTargetDistance(20000.0, halfWidthFrac: 0.20);
      expect(target.minM, 16000.0);
      expect(target.maxM, 24000.0);
    });

    test('is satisfied by the exact target', () {
      final target = bandedTargetDistance(20000.0);
      expect(target.minM! <= 20000.0 && 20000.0 <= target.maxM!, isTrue);
    });
  });
}
