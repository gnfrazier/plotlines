// Story C2 (issue #38), FR18 — "rest days hold location ... without an
// active route and can carry anchors, itinerary detail, and scheduled
// events." A rest day's card on the Logistics tab used to show nothing but
// its Start/End/Rest badges; this covers the location picker, the
// title/note itinerary fields, and the promoted-content summary this story
// adds, wired through a real `currentTripProvider` the same way
// `logistics_tab_trip_duration_test.dart` (C1) already does.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/map/tap_to_pick_map.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/logistics_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

/// `TapToPickMap` drags in flutter_map/vector_map_tiles, which leaves a
/// ticker a single `pump()` doesn't fully settle — several short pumps
/// clear it (same pattern `trip_library_screen_test.dart` uses).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

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
  testWidgets('a route day shows no rest-day details', (tester) async {
    await _pump(tester, Day(id: 'd1', index: 1));
    expect(find.text('No location set'), findsNothing);
  });

  testWidgets('a rest day with no location shows "No location set" and a "Set location" action',
      (tester) async {
    await _pump(tester, Day(id: 'd1', index: 1, kind: 'rest'));
    expect(find.text('No location set'), findsOneWidget);
    expect(find.text('Set location'), findsOneWidget);
  });

  testWidgets('a rest day with a location shows it and offers Change/Clear', (tester) async {
    await _pump(
      tester,
      Day(id: 'd1', index: 1, kind: 'rest', location: const [-105.3, 40.0]),
    );
    expect(find.textContaining('40.00000'), findsOneWidget);
    expect(find.text('Change'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('tapping "Set location" opens a map picker and Save writes the picked point',
      (tester) async {
    final container = await _pump(tester, Day(id: 'd1', index: 1, kind: 'rest'));

    await tester.tap(find.text('Set location'));
    await _settle(tester);

    expect(find.byType(TapToPickMap), findsOneWidget);
    final map = tester.widget<TapToPickMap>(find.byType(TapToPickMap));
    map.onTap!(const [-105.25, 40.1]);
    await _settle(tester);

    await tester.tap(find.text('Save'));
    await _settle(tester);

    expect(container.read(currentTripProvider).days.single.location, const [-105.25, 40.1]);
  });

  testWidgets('clearing a location removes it', (tester) async {
    final container = await _pump(
      tester,
      Day(id: 'd1', index: 1, kind: 'rest', location: const [1.0, 2.0]),
    );

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(container.read(currentTripProvider).days.single.location, isNull);
  });

  testWidgets('editing the title and note fields writes itinerary detail', (tester) async {
    final container = await _pump(tester, Day(id: 'd1', index: 1, kind: 'rest'));

    await tester.enterText(find.widgetWithText(TextField, 'What this day is about'), 'Spa quarter');
    await tester.enterText(find.widgetWithText(TextField, 'Itinerary detail'), 'Soak all morning.');
    await tester.pump();

    final day = container.read(currentTripProvider).days.single;
    expect(day.title, 'Spa quarter');
    expect(day.note, 'Soak all morning.');
  });

  testWidgets('promoted anchors and scheduled events on the day show as a summary', (tester) async {
    await _pump(
      tester,
      Day(
        id: 'd1',
        index: 1,
        kind: 'rest',
        nodes: [
          Node(id: 'n1', kind: NodeKind.poi, coord: const [0, 0]),
          Node(id: 'n2', kind: NodeKind.poi, coord: const [0, 0]),
          Node(
            id: 'n3',
            kind: NodeKind.event,
            coord: const [0, 0],
            scheduled: ScheduledWindow(opensAt: '2026-09-12T09:00:00Z'),
          ),
        ],
      ),
    );

    // PlotBadge uppercases its label.
    expect(find.text('2 ANCHORS'), findsOneWidget);
    expect(find.text('1 SCHEDULED EVENT'), findsOneWidget);
  });
}
