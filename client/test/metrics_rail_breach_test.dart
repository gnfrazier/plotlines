// Story C3 (issue #39), FR19 — "an indicator when a passage breaches a
// threshold ... reflected in the dashboard." `metrics_rail.dart` is D1's
// (FR31) dashboard — the Route tab's right rail — and its BY DAY breakdown
// showed plain distance bars with no indication a day had breached its
// per-mode limit. This pins the warning icon `_BarRow` now shows, driven by
// `computeDayLimitBreaches` (`domain/day.dart`), the same function the day
// timeline strip's breach chip uses (`day_timeline_strip_per_mode_breach_test.dart`)
// — one computation, two surfaces, so they can never disagree.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/sidecar_manager.dart' show CapabilityStatus;
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/metrics_rail.dart';

Segment _leg(String id, String mode, double distanceM) => Segment(
      id: id,
      mode: mode,
      shape: 'point_to_point',
      metrics: RouteMetrics(distanceM: distanceM),
    );

Future<void> _pump(WidgetTester tester, List<Day> days) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: MetricsRail(
        trip: Trip(
          id: 'trip-1',
          title: 'Test trip',
          createdAt: '2026-08-25T00:00:00Z',
          updatedAt: '2026-08-25T00:00:00Z',
          days: days,
        ),
        selectedSegment: null,
        elevationCapability: const CapabilityStatus(ready: true),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('a day within its limit shows no warning icon on its BY DAY row', (tester) async {
    await _pump(tester, [
      Day(
        id: 'd1',
        index: 1,
        segments: [_leg('s1', 'cycling', 50000)],
        limits: {'cycling': DayLimit(minM: 20000, maxM: 80000)},
      ),
    ]);
    expect(find.text('Day 1'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('a day breaching its limit shows a warning icon on its BY DAY row', (tester) async {
    await _pump(tester, [
      Day(
        id: 'd1',
        index: 1,
        segments: [_leg('s1', 'hiking', 5000)],
        limits: {'hiking': DayLimit(minM: 20000)},
      ),
    ]);
    expect(find.text('Day 1'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('only the breaching day is flagged among several', (tester) async {
    await _pump(tester, [
      Day(
        id: 'd1',
        index: 1,
        segments: [_leg('s1', 'cycling', 50000)],
        limits: {'cycling': DayLimit(minM: 20000, maxM: 80000)},
      ),
      Day(
        id: 'd2',
        index: 2,
        segments: [_leg('s2', 'cycling', 150000)],
        limits: {'cycling': DayLimit(maxM: 80000)},
      ),
    ]);
    expect(find.text('Day 1'), findsOneWidget);
    expect(find.text('Day 2'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('a day with no limits at all shows no warning icon', (tester) async {
    await _pump(tester, [Day(id: 'd1', index: 1, segments: [_leg('s1', 'cycling', 5000)])]);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });
}
