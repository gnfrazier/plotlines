// FR37 / E1 — the Content tab's passage/day content section
// (`_PassageAndDayContent`): a passage's own note/media and a day's own,
// both distinct from any role's (covered separately in
// `anchor_promotion_panel_test.dart`) and from each other. Wired through a
// real `currentTripProvider`, the same pattern
// `logistics_tab_rest_day_test.dart` (C2) already uses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/content_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';

Future<ProviderContainer> _pump(WidgetTester tester) async {
  // The section is inside an `ExpansionTile` below the node chips — a
  // taller test surface keeps it reachable without a scroll gesture (same
  // reasoning `roster_tab_test.dart` documents for its own ListView).
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer(
    overrides: [selectedSegmentProvider.overrideWith((ref) => ('day-1', 'seg-1'))],
  );
  addTearDown(container.dispose);
  final segment = Segment(
    id: 'seg-1',
    mode: 'cycling',
    shape: 'point_to_point',
    start: const [-105.27, 40.02],
    end: const [-105.20, 40.05],
  );
  container.read(currentTripProvider.notifier).open(
        Trip(
          id: 't1',
          title: 'Test trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          days: [Day(id: 'day-1', index: 1, segments: [segment])],
        ),
      );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ContentTab(trip: ref.watch(currentTripProvider)),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  testWidgets('starts collapsed and marked empty', (tester) async {
    await _pump(tester);
    expect(find.text('PASSAGE & DAY CONTENT (empty)'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Passage note'), findsNothing);
  });

  testWidgets('typing into the passage and day note fields writes to distinct trip fields', (tester) async {
    final container = await _pump(tester);
    await tester.tap(find.text('PASSAGE & DAY CONTENT (empty)'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Passage note'), 'Watch for gravel.');
    await tester.enterText(find.widgetWithText(TextField, 'Day note'), 'Camp at the shelter.');
    await tester.pump();

    final trip = container.read(currentTripProvider);
    expect(trip.days.single.segments.single.note, 'Watch for gravel.');
    expect(trip.days.single.note, 'Camp at the shelter.');
  });

  testWidgets('after content is added, the section header no longer reads empty', (tester) async {
    final container = await _pump(tester);
    container.read(currentTripProvider.notifier).updateSegmentNote('day-1', 'seg-1', 'Passage note.');
    await tester.pump();

    expect(find.text('PASSAGE & DAY CONTENT'), findsOneWidget);
    expect(find.text('PASSAGE & DAY CONTENT (empty)'), findsNothing);
  });
}
