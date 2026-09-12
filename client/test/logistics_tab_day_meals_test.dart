// FR25 (Story C9) — a meal pinned to a day ([MealResponsibility.dayId])
// shows on that day's own Logistics-tab card, not only in the standalone
// MEALS list at the bottom of the tab. Mirrors the pump style
// `logistics_tab_rest_day_test.dart` already established for a real
// `currentTripProvider` plus `sidecarManagerProvider` (`LogisticsTab` reaches
// the lodging section's candidate map even when nothing is fetched).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/logistics_tab.dart';
import 'package:plotlines_client/state/current_roster_provider.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'support/display_units.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

Future<ProviderContainer> _pump(WidgetTester tester, List<Day> days) async {
  // A tall surface so every day card and section renders without needing to
  // scroll the tab's outer `ListView` into view — the same setup
  // `gear_section_test.dart`/`meal_section_test.dart` use.
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer(overrides: [
    metricUnits(),
    sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
  ]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(
        Trip(
          id: 't1',
          title: 'Test trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
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
  await tester.pump();
  return container;
}

void main() {
  testWidgets('a meal pinned to this day shows on its own card', (tester) async {
    final container = await _pump(tester, [
      Day(id: 'd1', index: 1, kind: 'rest'),
      Day(id: 'd2', index: 2, kind: 'rest'),
    ]);
    container.read(currentRosterProvider.notifier).addMeal(
          const MealResponsibility(id: 'm1', label: 'Night 2 dinner', dayId: 'd2'),
        );
    await tester.pump();

    // Once on Day 2's own card, once more in the standalone MEALS list —
    // this is additive, not a replacement for the trip-wide list.
    expect(find.text('Night 2 dinner'), findsNWidgets(2));
    expect(find.byIcon(Icons.restaurant_outlined), findsOneWidget); // only Day 2's card
  });

  testWidgets('a meal with no day pin shows on no day card', (tester) async {
    final container = await _pump(tester, [Day(id: 'd1', index: 1, kind: 'rest')]);
    container.read(currentRosterProvider.notifier).addMeal(
          const MealResponsibility(id: 'm1', label: 'Trip-wide snacks'),
        );
    await tester.pump();

    // It still shows in the standalone MEALS section — just not attached to
    // a day card's own MEALS sub-card (which only renders when non-empty).
    expect(find.text('Trip-wide snacks'), findsOneWidget);
    expect(find.byIcon(Icons.restaurant_outlined), findsNothing);
  });

  testWidgets('shows who is responsible when the meal has cooks assigned', (tester) async {
    final container = await _pump(tester, [Day(id: 'd1', index: 1, kind: 'rest')]);
    final roster = container.read(currentRosterProvider.notifier);
    roster.addEntry('ann', 'Ann');
    roster.addMeal(const MealResponsibility(id: 'm1', label: 'Dinner', dayId: 'd1'));
    roster.setMealCooks('m1', {'ann'});
    await tester.pump();

    expect(find.text('Dinner — Ann'), findsOneWidget);
  });

  testWidgets('a day with no pinned meals renders no MEALS sub-card', (tester) async {
    await _pump(tester, [Day(id: 'd1', index: 1, kind: 'rest')]);
    expect(find.byIcon(Icons.restaurant_outlined), findsNothing);
  });
}
