// FR25 / C9 (issue #45) — the group-meal mutations on `currentRosterProvider`:
// add / update / assign / remove, mirroring the C8 gear tests' shape.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_roster_provider.dart';

void main() {
  late ProviderContainer container;
  CurrentRosterNotifier notifier() => container.read(currentRosterProvider.notifier);
  TripRoster roster() => container.read(currentRosterProvider);

  setUp(() {
    container = ProviderContainer();
  });
  tearDown(() => container.dispose());

  test('addMeal appends; a duplicate id is a no-op', () {
    notifier().addMeal(const MealResponsibility(id: 'm1', label: 'Night 1 dinner'));
    notifier().addMeal(const MealResponsibility(id: 'm1', label: 'Renamed'));
    expect(roster().meals.map((m) => m.label), ['Night 1 dinner']);
  });

  test('updateMeal edits the label and day pin in place', () {
    notifier().addMeal(const MealResponsibility(id: 'm1', label: 'Dinner'));
    notifier().updateMeal('m1', label: 'Night 2 dinner', dayId: 'd2');
    final m = roster().meals.single;
    expect(m.label, 'Night 2 dinner');
    expect(m.dayId, 'd2');
  });

  test('updateMeal clears the day pin via clearDayId', () {
    notifier().addMeal(const MealResponsibility(id: 'm1', label: 'Dinner', dayId: 'd1'));
    notifier().updateMeal('m1', clearDayId: true);
    expect(roster().meals.single.dayId, isNull);
  });

  test('setMealCooks sets who is responsible', () {
    notifier().addMeal(const MealResponsibility(id: 'm1', label: 'Dinner'));
    notifier().setMealCooks('m1', {'ann', 'bo'});
    expect(roster().meals.single.cookIds, {'ann', 'bo'});
  });

  test('removeMeal drops just that line', () {
    notifier().addMeal(const MealResponsibility(id: 'a', label: 'A'));
    notifier().addMeal(const MealResponsibility(id: 'b', label: 'B'));
    notifier().removeMeal('a');
    expect(roster().meals.map((m) => m.id), ['b']);
  });

  test('removing a Character strips them from a meal and drops an orphaned one', () {
    notifier().addEntry('ann', 'Ann');
    notifier().addEntry('bo', 'Bo');
    notifier().addMeal(const MealResponsibility(id: 'dinner', label: 'Dinner', cookIds: {'ann', 'bo'}));
    notifier().addMeal(const MealResponsibility(id: 'breakfast', label: 'Breakfast', cookIds: {'bo'}));

    notifier().removeEntry('bo');

    expect(roster().meals.firstWhere((m) => m.id == 'dinner').cookIds, {'ann'});
    // breakfast was bo-only → orphaned → dropped.
    expect(roster().meals.map((m) => m.id), ['dinner']);
  });
}
