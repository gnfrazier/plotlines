// Story C3 (issue #39), FR19 — "per-mode min/max distance boundaries."
// `Day.limits`' keys are travel modes; a day mixing cycling and hiking needs
// its own band per mode. The editor used to write a single fixed
// (non-mode) key — this covers the per-mode rework: one row per limited
// mode, an "add a mode limit" affordance, and per-row removal — wired
// through a real `currentTripProvider` the same way the C1/C2 Logistics
// tests already do.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/logistics_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Segment _leg(String id, String mode) => Segment(id: id, mode: mode, shape: 'point_to_point');

Future<ProviderContainer> _pump(WidgetTester tester, Day day) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(
        Trip(
          id: 't1',
          title: 'Test trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          days: [day],
        ),
      );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => LogisticsTab(
              trip: ref.watch(currentTripProvider),
              onOpenSegment: (_, _) {},
            ),
          ),
        ),
      ),
    ),
  );
  return container;
}

void main() {
  testWidgets('a day with no limits shows no limit rows', (tester) async {
    await _pump(tester, Day(id: 'd1', index: 1, segments: [_leg('s1', 'cycling')]));
    expect(find.text('DAY LIMITS (km)'), findsOneWidget);
    // Just the trip-length field — no limit row until one is added.
    expect(find.byType(TextField), findsNWidgets(1));
  });

  testWidgets('an existing per-mode limit shows its own row, labelled by mode', (tester) async {
    await _pump(
      tester,
      Day(
        id: 'd1',
        index: 1,
        segments: [_leg('s1', 'hiking')],
        limits: {'hiking': DayLimit(minM: 10000, maxM: 20000)},
      ),
    );
    expect(find.text('Hike'), findsOneWidget); // the limit row's mode label
    expect(find.text('10'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);
  });

  testWidgets('a day mixing two modes can carry a limit row for each, independently', (tester) async {
    final container = await _pump(
      tester,
      Day(
        id: 'd1',
        index: 1,
        segments: [_leg('s1', 'cycling'), _leg('s2', 'hiking')],
        limits: {
          'cycling': DayLimit(maxM: 80000),
          'hiking': DayLimit(minM: 5000),
        },
      ),
    );

    // Trip-length field, then cycling's min/max, then hiking's min/max —
    // rows sort by mode name, and `_TripDurationCard` renders first.
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(5));

    // Editing hiking's min (index 3) doesn't touch cycling's max.
    await tester.enterText(fields.at(3), '6');
    await tester.pump();
    final limits = container.read(currentTripProvider).days.single.limits;
    expect(limits['hiking']!.minM, 6000);
    expect(limits['cycling']!.maxM, 80000);
  });

  testWidgets('adding a mode limit via the menu creates an empty row for that mode', (tester) async {
    final container = await _pump(tester, Day(id: 'd1', index: 1, segments: [_leg('s1', 'cycling')]));

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ride').last);
    await tester.pumpAndSettle();

    expect(container.read(currentTripProvider).days.single.limits.containsKey('cycling'), isTrue);
  });

  testWidgets('removing a mode limit clears only that mode', (tester) async {
    final container = await _pump(
      tester,
      Day(
        id: 'd1',
        index: 1,
        segments: [_leg('s1', 'cycling'), _leg('s2', 'hiking')],
        limits: {
          'cycling': DayLimit(maxM: 80000),
          'hiking': DayLimit(minM: 5000),
        },
      ),
    );

    await tester.tap(find.widgetWithIcon(IconButton, Icons.close).first);
    await tester.pump();

    final limits = container.read(currentTripProvider).days.single.limits;
    expect(limits.length, 1);
  });
}
