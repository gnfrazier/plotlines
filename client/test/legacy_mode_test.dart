// Issue #315 — `mountain_biking` / `packrafting` / `riverboarding` left the
// travel_mode enum. `legacy_mode.dart` folds the old spelling forward, and
// the domain parsers that read a mode value off a stored payload apply it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  test('canonicalMode folds a removed value onto its category', () {
    expect(canonicalMode('mountain_biking'), 'cycling');
    expect(canonicalMode('packrafting'), 'paddling');
    expect(canonicalMode('riverboarding'), 'paddling');
    expect(canonicalMode('cycling'), 'cycling');
    expect(canonicalMode('teleportation'), 'teleportation');
  });

  test('migrateLegacyMode seeds the discipline unless one is already stored', () {
    expect(migrateLegacyMode('mountain_biking'),
        (mode: 'cycling', discipline: 'mountain'));
    expect(migrateLegacyMode('mountain_biking', discipline: 'gravel'),
        (mode: 'cycling', discipline: 'gravel'));
    expect(migrateLegacyMode('hiking'), (mode: 'hiking', discipline: null));
  });

  test('every alias maps to a real category and discipline', () {
    for (final entry in kLegacyModeAliases.entries) {
      expect(kTravelCategories, contains(entry.value.$1), reason: entry.key);
      expect(kDisciplineKeys, contains(entry.value.$2), reason: entry.key);
      expect(categoryOfDiscipline(entry.value.$2), entry.value.$1, reason: entry.key);
    }
  });

  test('Transition.fromJson folds a legacy from/to mode', () {
    final t = Transition.fromJson({
      'id': 't1', 'from_segment_id': 'a', 'to_segment_id': 'b',
      'from_mode': 'mountain_biking', 'to_mode': 'packrafting',
    });
    expect(t.fromMode, 'cycling');
    expect(t.toMode, 'paddling');
    expect(t.isModeChange, isTrue);
  });

  test('RollUp.fromJson folds a legacy by_mode key', () {
    final r = RollUp.fromJson({
      'by_mode': {
        'mountain_biking': {'distance_m': 1000.0},
      },
    });
    expect(r.byMode.keys, ['cycling']);
    expect(r.byMode['cycling']!.distanceM, 1000.0);
  });
}
