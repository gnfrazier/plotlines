// FR25 / C9 (issue #45) — the group-meal authoring surface on the Logistics
// tab: the empty state's next action, adding a meal through the dialog, and
// assigning meal responsibility to the roster.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/meal_section.dart';
import 'package:plotlines_client/state/current_roster_provider.dart';

Trip _trip({List<Day> days = const []}) => Trip(
      id: 't1',
      title: 'Test',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: days,
    );

Future<ProviderContainer> _pump(WidgetTester tester, Trip trip) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: MealSection(trip: trip))),
      ),
    ),
  );
  return container;
}

TripRoster _roster(ProviderContainer c) => c.read(currentRosterProvider);
CurrentRosterNotifier _notifier(ProviderContainer c) => c.read(currentRosterProvider.notifier);

void main() {
  testWidgets('empty state carries a next action', (tester) async {
    await _pump(tester, _trip());
    expect(find.textContaining('No group meals yet'), findsOneWidget);
  });

  testWidgets('adding a meal through the dialog lands it trip-wide by default', (tester) async {
    final c = await _pump(tester, _trip());

    await tester.tap(find.text('Add meal'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Meal'), 'Night 2 dinner');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(_roster(c).meals.single.label, 'Night 2 dinner');
    expect(_roster(c).meals.single.dayId, isNull);
    expect(find.text('Night 2 dinner'), findsOneWidget);
  });

  testWidgets('a meal pinned to a day shows its day badge', (tester) async {
    final day = Day(id: 'd1', index: 1);
    final c = await _pump(tester, _trip(days: [day]));
    _notifier(c).addMeal(const MealResponsibility(id: 'm1', label: 'Dinner', dayId: 'd1'));
    await tester.pump();
    expect(find.text('DAY 1'), findsOneWidget); // PlotBadge upper-cases its label
  });

  testWidgets('meal responsibility can be assigned to a roster Character', (tester) async {
    final c = await _pump(tester, _trip());
    _notifier(c).addEntry('ann', 'Ann');
    _notifier(c).addMeal(const MealResponsibility(id: 'm1', label: 'Dinner'));
    await tester.pump();

    await tester.tap(find.widgetWithText(FilterChip, 'Ann'));
    await tester.pump();

    expect(_roster(c).meals.single.cookIds, {'ann'});
  });

  testWidgets('a meal with an empty roster points at the Roster tab', (tester) async {
    final c = await _pump(tester, _trip());
    _notifier(c).addMeal(const MealResponsibility(id: 'm1', label: 'Dinner'));
    await tester.pump();
    expect(find.textContaining('Add Characters on the Roster tab'), findsOneWidget);
  });
}
