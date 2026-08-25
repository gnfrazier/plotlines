// FR117/FR119 (Story A0) — the explore/compose planning-mode switch: the
// mode provider's default, and the two pure rules that make "switch either
// way, no work lost" true (`composeAwareTargetM`, `loosenedTargetDistanceM`).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';

void main() {
  group('dayPlanningModeProvider', () {
    test('defaults to explore for any day id', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(dayPlanningModeProvider('day-1')), PlanningMode.explore);
      expect(container.read(dayPlanningModeProvider('day-2')), PlanningMode.explore);
    });

    test('is scoped per day id — switching one day never affects another', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(dayPlanningModeProvider('day-1').notifier).state = PlanningMode.compose;

      expect(container.read(dayPlanningModeProvider('day-1')), PlanningMode.compose);
      expect(container.read(dayPlanningModeProvider('day-2')), PlanningMode.explore);
    });
  });

  group('composeAwareTargetM', () {
    test('explore sends the authored target distance as the solve constraint', () {
      final target = TargetDistance(valueM: 42000);
      expect(composeAwareTargetM(PlanningMode.explore, target), 42000);
    });

    test('explore with no authored target sends none', () {
      expect(composeAwareTargetM(PlanningMode.explore, null), isNull);
    });

    test('compose sends no target even when one is authored — ARCH §7.7\'s '
        '"target_distance=None is a first-class input"', () {
      final target = TargetDistance(valueM: 42000);
      expect(composeAwareTargetM(PlanningMode.compose, target), isNull);
    });
  });

  group('loosenedTargetDistanceM', () {
    test('backfills from the realized outcome when no explore target exists yet', () {
      expect(
        loosenedTargetDistanceM(existingTarget: null, realizedDistanceM: 31500),
        31500,
      );
    });

    test('an existing explore target always wins over the realized outcome — '
        'FR119 never overwrites authored work', () {
      final existing = TargetDistance(valueM: 20000);
      expect(
        loosenedTargetDistanceM(existingTarget: existing, realizedDistanceM: 31500),
        20000,
      );
    });

    test('both absent stays absent', () {
      expect(
        loosenedTargetDistanceM(existingTarget: null, realizedDistanceM: null),
        isNull,
      );
    });
  });
}
