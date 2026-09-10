// FR24 / C8 (issue #44) — the gear-checklist mutations on
// `currentRosterProvider`: add / update / assign / remove, and the two
// pairings the notifier owns so callers do not have to (turning a line
// personal clears its assignees; removing a Character strips them from every
// shared line).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_roster_provider.dart';

void main() {
  late ProviderContainer container;
  CurrentRosterNotifier notifier() =>
      container.read(currentRosterProvider.notifier);
  TripRoster roster() => container.read(currentRosterProvider);

  setUp(() {
    container = ProviderContainer();
  });
  tearDown(() => container.dispose());

  test('addGearItem appends; a duplicate id is a no-op', () {
    notifier().addGearItem(const GearItem(id: 'a', label: 'Helmet'));
    notifier().addGearItem(const GearItem(id: 'a', label: 'Helmet again'));
    expect(roster().gear.map((g) => g.label), ['Helmet']);
  });

  test('updateGearItem edits label, scope and necessity in place', () {
    notifier().addGearItem(const GearItem(id: 'a', label: 'lamp'));
    notifier().updateGearItem(
      'a',
      label: 'Headlamp',
      necessity: GearNecessity.mandatory,
      scope: GearScope.mode('cycling'),
    );
    final g = roster().gear.single;
    expect(g.label, 'Headlamp');
    expect(g.isMandatory, isTrue);
    expect(g.scope, GearScope.mode('cycling'));
  });

  test('turning a line personal clears its assignees', () {
    notifier().addGearItem(
      const GearItem(id: 'a', label: 'Tent', shared: true, assigneeIds: {'ann', 'bo'}),
    );
    notifier().updateGearItem('a', shared: false);
    final g = roster().gear.single;
    expect(g.shared, isFalse);
    expect(g.assigneeIds, isEmpty);
  });

  test('setGearAssignees only bites on a shared line', () {
    notifier().addGearItem(const GearItem(id: 'shared', label: 'Stove', shared: true));
    notifier().addGearItem(const GearItem(id: 'personal', label: 'Socks'));
    notifier().setGearAssignees('shared', {'ann'});
    notifier().setGearAssignees('personal', {'ann'});
    expect(roster().gear.firstWhere((g) => g.id == 'shared').assigneeIds, {'ann'});
    expect(roster().gear.firstWhere((g) => g.id == 'personal').assigneeIds, isEmpty);
  });

  test('removeGearItem drops just that line', () {
    notifier().addGearItem(const GearItem(id: 'a', label: 'A'));
    notifier().addGearItem(const GearItem(id: 'b', label: 'B'));
    notifier().removeGearItem('a');
    expect(roster().gear.map((g) => g.id), ['b']);
  });

  test('removing a Character strips them from shared gear and drops an orphaned line', () {
    notifier().addEntry('ann', 'Ann');
    notifier().addEntry('bo', 'Bo');
    notifier().addGearItem(
      const GearItem(id: 'tent', label: 'Tent', shared: true, assigneeIds: {'ann', 'bo'}),
    );
    notifier().addGearItem(
      const GearItem(id: 'stove', label: 'Stove', shared: true, assigneeIds: {'bo'}),
    );
    notifier().addGearItem(
      const GearItem(id: 'lamp', label: 'Headlamp', necessity: GearNecessity.mandatory),
    );

    notifier().removeEntry('bo');

    expect(roster().gear.firstWhere((g) => g.id == 'tent').assigneeIds, {'ann'});
    // stove was bo-only → orphaned → dropped; the personal line is untouched.
    expect(roster().gear.map((g) => g.id), ['tent', 'lamp']);
  });
}
