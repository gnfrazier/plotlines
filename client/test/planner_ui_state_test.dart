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

  group('daySelection (issue #323)', () {
    Segment seg(String id) => Segment(id: id, mode: 'cycling', shape: 'loop');
    Trip tripOf(List<Day> days) => Trip(
          id: 'trip-1',
          title: 'T',
          createdAt: '2026-09-08T00:00:00Z',
          updatedAt: '2026-09-08T00:00:00Z',
          days: days,
        );

    test('selects the day\'s first segment', () {
      final trip = tripOf([
        Day(id: 'day-1', index: 1, segments: [seg('a'), seg('b')]),
        Day(id: 'day-2', index: 2, segments: [seg('c')]),
      ]);
      expect(daySelection(trip, 'day-1'), ('day-1', 'a'));
      expect(daySelection(trip, 'day-2'), ('day-2', 'c'));
    });

    test('a day with no segments clears the selection rather than pointing elsewhere', () {
      final trip = tripOf([
        Day(id: 'day-1', index: 1, segments: [seg('a')]),
        Day(id: 'day-2', index: 2, kind: 'rest'),
        Day(id: 'day-3', index: 3), // route day, not yet solved
      ]);
      expect(daySelection(trip, 'day-2'), isNull);
      expect(daySelection(trip, 'day-3'), isNull);
    });

    test('an unknown day id selects nothing', () {
      final trip = tripOf([Day(id: 'day-1', index: 1, segments: [seg('a')])]);
      expect(daySelection(trip, 'nope'), isNull);
    });
  });

  group('nodeKindIsRoutingConstraint (issue #322)', () {
    test('via, start, finish and the portage ends pin the route', () {
      for (final kind in [
        NodeKind.via,
        NodeKind.start,
        NodeKind.finish,
        NodeKind.portageStart,
        NodeKind.portageEnd,
      ]) {
        expect(nodeKindIsRoutingConstraint(kind), isTrue, reason: '$kind');
      }
    });

    test('annotation kinds never invalidate a solved geometry', () {
      for (final kind in [
        NodeKind.waypoint,
        NodeKind.regroup,
        NodeKind.restStop,
        NodeKind.poi,
        NodeKind.transition,
        NodeKind.event,
      ]) {
        expect(nodeKindIsRoutingConstraint(kind), isFalse, reason: '$kind');
      }
    });

    test('every NodeKind is classified — a new kind cannot slip through', () {
      // The switch is exhaustive over `NodeKind.values`; this asserts the
      // enum and the classifier have not drifted apart.
      for (final kind in NodeKind.values) {
        expect(() => nodeKindIsRoutingConstraint(kind), returnsNormally);
      }
    });
  });
}
