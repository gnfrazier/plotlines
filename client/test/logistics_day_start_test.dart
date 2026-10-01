// Issue #563 — the Logistics tab's START row: an Author sets a day's start
// time on the day's own clock and zone, and it is stored as UTC + IANA zone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/day_start_editor.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Trip _trip(Day day, {TripDuration? duration}) => Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [day],
      duration: duration,
    );

Future<ProviderContainer> _pump(WidgetTester tester, Trip trip) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(trip);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) {
            final t = ref.watch(currentTripProvider);
            return DayStartRow(trip: t, day: t.days.single);
          },
        ),
      ),
    ),
  ));
  return container;
}

void main() {
  testWidgets('setting a start stores the day\'s wall clock as UTC beside its zone', (tester) async {
    final container = await _pump(tester, _trip(Day(id: 'd1', index: 1, date: '2026-07-04')));
    expect(find.text('No start time — no arrival estimate'), findsOneWidget);

    await tester.tap(find.text('Set start'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('day-start-zone')), 'America/Denver');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('day-start-save')));
    await tester.pumpAndSettle();

    final day = container.read(currentTripProvider).days.single;
    // The dialog opens on 8:00; 08:00 MDT on 4 July is 14:00Z.
    expect(day.startAt, '2026-07-04T14:00:00Z');
    expect(day.startTimezone, 'America/Denver');
    expect(find.textContaining('MDT · America/Denver'), findsOneWidget);
  });

  testWidgets('a day takes its date from the trip dates when it has none of its own', (tester) async {
    final trip = _trip(Day(id: 'd1', index: 1), duration: TripDuration(startDate: '2026-01-10'));
    expect(dayCalendarDate(trip, trip.days.single), '2026-01-10');
    final container = await _pump(tester, trip);
    await tester.tap(find.text('Set start'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('day-start-zone')), 'America/New_York');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('day-start-save')));
    await tester.pumpAndSettle();
    expect(container.read(currentTripProvider).days.single.startAt, '2026-01-10T13:00:00Z');
  });

  testWidgets('an unknown zone cannot be saved', (tester) async {
    await _pump(tester, _trip(Day(id: 'd1', index: 1, date: '2026-07-04')));
    await tester.tap(find.text('Set start'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('day-start-zone')), 'Mars/Olympus');
    await tester.pumpAndSettle();
    expect(find.text('Not a known time zone'), findsOneWidget);
    final save = tester.widget<FilledButton>(find.byKey(const ValueKey('day-start-save')));
    expect(save.onPressed, isNull);
  });

  testWidgets('with no date anywhere the dialog says why, and offers no Save', (tester) async {
    await _pump(tester, _trip(Day(id: 'd1', index: 1)));
    await tester.tap(find.text('Set start'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Set the trip dates'), findsOneWidget);
    expect(find.byKey(const ValueKey('day-start-save')), findsNothing);
  });

  testWidgets('Clear takes the start off', (tester) async {
    final container = await _pump(
        tester,
        _trip(Day(id: 'd1', index: 1, date: '2026-07-04',
            startAt: '2026-07-04T14:00:00Z', startTimezone: 'America/Denver')));
    await tester.tap(find.text('Edit start'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(container.read(currentTripProvider).days.single.startAt, isNull);
  });
}
