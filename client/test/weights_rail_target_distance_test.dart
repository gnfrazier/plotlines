// Story A8 (issue #25) — target-distance control for loop/out-and-back only,
// banded by default in explore mode, widenable but never removable, and a
// reported outcome (not a constraint) in compose regardless of shape.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';

Segment _segment({required String shape, TargetDistance? targetDistance}) => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: shape,
      start: const [-105.27, 40.02],
      end: shape == 'point_to_point' ? const [-105.2, 40.05] : null,
      targetDistance: targetDistance,
      metrics: RouteMetrics(distanceM: 12000),
    );

Trip _trip(Segment segment) {
  final day = Day(id: 'day-1', index: 1, segments: [segment]);
  return Trip(
    id: 'trip-1',
    title: 'Test trip',
    createdAt: '2026-08-25T00:00:00Z',
    updatedAt: '2026-08-25T00:00:00Z',
    days: [day],
  );
}

Future<void> _pump(WidgetTester tester, Segment segment, {PlanningMode mode = PlanningMode.explore}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentTripProvider.overrideWith((ref) => CurrentTripNotifier(ref)..open(_trip(segment))),
        dayPlanningModeProvider('day-1').overrideWith((ref) => mode),
      ],
      child: MaterialApp(
        home: Scaffold(body: WeightsRail(dayId: 'day-1', segment: segment)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('point-to-point has no target-distance input (explore)', () {
    testWidgets('no target-distance field at all', (tester) async {
      await _pump(tester, _segment(shape: 'point_to_point'));

      expect(find.text('Target distance (km)'), findsNothing);
    });

    testWidgets('a pre-existing target distance on the segment is not shown either', (tester) async {
      // Defensive: nothing currently sets one for point_to_point, but the
      // control must stay hidden even if a stray value is present.
      await _pump(
        tester,
        _segment(shape: 'point_to_point', targetDistance: TargetDistance(valueM: 5000)),
      );

      expect(find.text('Target distance (km)'), findsNothing);
    });
  });

  group('loop / out-and-back — banded by default', () {
    for (final shape in ['loop', 'out_and_back']) {
      testWidgets('$shape shows the target-distance field', (tester) async {
        await _pump(tester, _segment(shape: shape));

        expect(find.text('Target distance (km)'), findsOneWidget);
      });
    }

    testWidgets('a banded target renders its band row, with no remove control', (tester) async {
      final segment = _segment(
        shape: 'loop',
        targetDistance: TargetDistance(valueM: 20000, minM: 18000, maxM: 22000),
      );
      await _pump(tester, segment);

      expect(find.textContaining('distance_m'), findsOneWidget);
      // FR8/A8's AC: never dropped from the constraint set — no remove icon
      // anywhere in this fixture (its `bands` list is otherwise empty, so
      // any close icon found could only belong to the distance row).
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.textContaining('Banded by default'), findsOneWidget);
    });

    testWidgets('an unbanded target (defensive/legacy) shows no band row', (tester) async {
      final segment = _segment(shape: 'loop', targetDistance: TargetDistance(valueM: 20000));
      await _pump(tester, segment);

      expect(find.text('Target distance (km)'), findsOneWidget);
      expect(find.textContaining('distance_m'), findsNothing);
    });

    testWidgets('widening the band calls updateSegmentTargetDistanceBand, leaving the '
        'target value untouched', (tester) async {
      final segment = _segment(
        shape: 'loop',
        targetDistance: TargetDistance(valueM: 20000, minM: 18000, maxM: 22000),
      );
      await _pump(tester, segment);

      final maxField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'max',
      );
      expect(maxField, findsOneWidget);
      await tester.enterText(maxField, '30000');
      await tester.pump();

      final container = ProviderScope.containerOf(tester.element(find.byType(WeightsRail)));
      final updated = container.read(currentTripProvider).days.single.segments.single.targetDistance;
      expect(updated!.valueM, 20000); // untouched
      expect(updated.maxM, 30000.0);
      expect(updated.minM, 18000.0); // the other side is untouched too
    });
  });

  group('compose — a reported outcome regardless of shape', () {
    for (final shape in ['loop', 'out_and_back', 'point_to_point']) {
      testWidgets('$shape shows the realized-outcome card, not an editable field', (tester) async {
        await _pump(tester, _segment(shape: shape), mode: PlanningMode.compose);

        expect(find.text('DISTANCE — REPORTED OUTCOME'), findsOneWidget);
        expect(find.text('Target distance (km)'), findsNothing);
      });
    }
  });
}
