// Story C3 (issue #39), FR19 — "per-mode min/max distance boundaries, with
// an indicator when a passage breaches a threshold." `Day.limits`' keys are
// travel modes: a day mixing cycling and hiking can breach one mode's band
// without the other, and both need their own indicator. This exercises that
// directly, against `computeDayLimitBreaches` (`domain/day.dart`) — the one
// place the breach set is computed, shared with `metrics_rail.dart`'s
// dashboard indicator (`metrics_rail_breach_test.dart`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/day_timeline_strip.dart';

Future<void> _pump(WidgetTester tester, Day day) => tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: DayTimelineStrip(
              trip: Trip(
                id: 't1',
                title: 'Test trip',
                createdAt: '2026-01-01T00:00:00Z',
                updatedAt: '2026-01-01T00:00:00Z',
                days: [day],
              ),
              activeDayId: day.id,
              onSelectDay: (_) {},
            ),
          ),
        ),
      ),
    );

Segment _leg(String id, String mode, double distanceM) => Segment(
      id: id,
      mode: mode,
      shape: 'point_to_point',
      metrics: RouteMetrics(distanceM: distanceM),
    );

void main() {
  testWidgets('a mixed-mode day can breach one mode\'s band without the other', (tester) async {
    final day = Day(
      id: 'day-1',
      index: 1,
      segments: [_leg('s1', 'cycling', 60000), _leg('s2', 'hiking', 5000)],
      limits: {
        'cycling': DayLimit(minM: 20000, maxM: 80000), // within band
        'hiking': DayLimit(minM: 10000), // below band
      },
    );
    await _pump(tester, day);

    expect(find.textContaining('Hike:'), findsOneWidget);
    expect(find.textContaining('below'), findsOneWidget);
    expect(find.textContaining('Ride:'), findsNothing);
  });

  testWidgets('both modes can breach independently, each with its own chip', (tester) async {
    final day = Day(
      id: 'day-1',
      index: 1,
      segments: [_leg('s1', 'cycling', 120000), _leg('s2', 'hiking', 2000)],
      limits: {
        'cycling': DayLimit(maxM: 80000), // over band
        'hiking': DayLimit(minM: 10000), // below band
      },
    );
    await _pump(tester, day);

    expect(find.textContaining('above'), findsOneWidget);
    expect(find.textContaining('below'), findsOneWidget);
  });

  testWidgets('a limit set for a mode absent from the day\'s segments produces no breach', (tester) async {
    final day = Day(
      id: 'day-1',
      index: 1,
      segments: [_leg('s1', 'cycling', 50000)],
      limits: {'hiking': DayLimit(minM: 10000)},
    );
    await _pump(tester, day);

    expect(find.textContaining('below'), findsNothing);
    expect(find.textContaining('above'), findsNothing);
  });

  testWidgets('a day with no limits shows no breach chip', (tester) async {
    final day = Day(id: 'day-1', index: 1, segments: [_leg('s1', 'cycling', 5000)]);
    await _pump(tester, day);

    expect(find.textContaining('below'), findsNothing);
    expect(find.textContaining('above'), findsNothing);
  });
}
