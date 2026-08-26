// Story C1 (issue #37), FR17 — "Authors define adventure duration
// (single-day, multi-day, multi-week) via start/end dates or a day count."
// Start/end dates already wrote `Trip.duration` from New Route's setup
// screen; this covers the day-count half and the persistent date editor
// this tab adds, both wired through `CurrentTripNotifier.setDayCount`/
// `setDuration` against a real `currentTripProvider` (a fixture `Trip`
// passed in as a widget argument alone would let a count change "pass"
// without any state actually moving).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/logistics_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Future<ProviderContainer> _pump(WidgetTester tester, List<Day> days, {TripDuration? duration}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(
        Trip(
          id: 't1',
          title: 'Test trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          duration: duration,
          days: days,
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

Future<void> _setDayCountField(WidgetTester tester, String value) async {
  await tester.enterText(find.byType(TextField).first, value);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the current day count and no dates set by default', (tester) async {
    await _pump(tester, [Day(id: 'd1', index: 1)]);
    expect(find.text('1'), findsWidgets); // the day-count field's text
    expect(find.text('No dates set'), findsOneWidget);
  });

  testWidgets('shows a formatted date range when the trip has one', (tester) async {
    await _pump(
      tester,
      [Day(id: 'd1', index: 1)],
      duration: TripDuration(startDate: '2026-09-12', endDate: '2026-09-15'),
    );
    expect(find.text('Sep 12 – Sep 15, 2026'), findsOneWidget);
  });

  testWidgets('raising the day count appends blank route days', (tester) async {
    final container = await _pump(tester, [Day(id: 'd1', index: 1)]);

    await _setDayCountField(tester, '3');

    expect(container.read(currentTripProvider).days, hasLength(3));
  });

  testWidgets('raising the day count with no dates records it on Trip.duration', (tester) async {
    final container = await _pump(tester, [Day(id: 'd1', index: 1)]);

    await _setDayCountField(tester, '5');

    expect(container.read(currentTripProvider).duration?.dayCount, 5);
  });

  testWidgets('lowering the day count past only empty trailing days needs no prompt', (tester) async {
    final container = await _pump(tester, [
      Day(id: 'd1', index: 1),
      Day(id: 'd2', index: 2),
      Day(id: 'd3', index: 3),
    ]);

    await _setDayCountField(tester, '1');

    expect(container.read(currentTripProvider).days, hasLength(1));
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('lowering the day count past content-holding days prompts before removing anything',
      (tester) async {
    final container = await _pump(tester, [
      Day(id: 'd1', index: 1),
      Day(
        id: 'd2',
        index: 2,
        segments: [Segment(id: 's2', mode: 'cycling', shape: 'loop')],
      ),
    ]);

    await _setDayCountField(tester, '1');

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('Day 2'), findsWidgets);
    // Nothing removed while the prompt is still open.
    expect(container.read(currentTripProvider).days, hasLength(2));

    await tester.tap(find.text('Remove explicitly'));
    await tester.pumpAndSettle();

    expect(container.read(currentTripProvider).days, hasLength(1));
  });

  testWidgets('choosing "Keep" leaves every day exactly as it was', (tester) async {
    final container = await _pump(tester, [
      Day(id: 'd1', index: 1),
      Day(
        id: 'd2',
        index: 2,
        segments: [Segment(id: 's2', mode: 'cycling', shape: 'loop')],
      ),
    ]);

    await _setDayCountField(tester, '1');
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();

    expect(container.read(currentTripProvider).days, hasLength(2));
    expect(find.text('2'), findsWidgets); // the field reverts to the real count
  });
}
