// FR134–FR136 / FR74b — `TripRoster` and its transforms: the JSON round-trip
// it is persisted through (`Trips.roster`), the "no dangling references"
// drop (`retainingPeople`), and the position-override clear used when a clone
// carries the roster but not the itinerary.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/roster.dart';

TripRoster _roster() => const TripRoster(
      entries: [
        RosterEntry(
          characterId: 'ann',
          name: 'Ann',
          groupLabel: 'Fast',
          subgroupLabel: 'Scouts',
          dayGroupOverrides: {'d1': 'Slow'},
          passageGroupOverrides: {'p1': 'Fast'},
        ),
        RosterEntry(characterId: 'bo', name: 'Bo', groupLabel: 'Slow'),
        RosterEntry(characterId: 'cy', name: 'Cy'),
      ],
      gear: [
        GearAssignment(id: 'g1', label: 'Tent', assigneeIds: {'ann', 'bo'}),
        GearAssignment(id: 'g2', label: 'Stove', assigneeIds: {'cy'}),
      ],
      meals: [
        MealResponsibility(id: 'm1', label: 'Night 1 dinner', dayId: 'd1', cookIds: {'bo'}),
        MealResponsibility(id: 'm2', label: 'Night 2 dinner', cookIds: {'ann', 'cy'}),
      ],
      authorNotes: [
        AuthorNote(subjectCharacterId: 'ann', body: 'Strong on scrambly ground.', updatedAt: '2024-06-01T00:00:00.000Z'),
        AuthorNote(subjectCharacterId: 'cy', body: 'New to multi-day.', updatedAt: '2025-01-15T00:00:00.000Z'),
      ],
    );

void main() {
  test('JSON round-trips every field with zero loss', () {
    final before = _roster();
    final after = TripRoster.fromJson(before.toJson());

    expect(after.entries.map((e) => e.characterId), ['ann', 'bo', 'cy']);
    final ann = after.entries.first;
    expect(ann.groupLabel, 'Fast');
    expect(ann.subgroupLabel, 'Scouts');
    expect(ann.dayGroupOverrides, {'d1': 'Slow'});
    expect(ann.passageGroupOverrides, {'p1': 'Fast'});
    expect(after.gear.map((g) => g.id), ['g1', 'g2']);
    expect(after.gear.first.assigneeIds, {'ann', 'bo'});
    expect(after.meals.firstWhere((m) => m.id == 'm1').dayId, 'd1');
    expect(after.authorNotes.map((n) => n.subjectCharacterId), ['ann', 'cy']);
    expect(after.authorNotes.first.updatedAt, '2024-06-01T00:00:00.000Z');
  });

  test('empty roster serialises to {} and back', () {
    expect(TripRoster.empty.toJson(), <String, dynamic>{});
    expect(TripRoster.fromJson(const {}).isEmpty, isTrue);
  });

  group('retainingPeople — no dangling references (ARCH §11.8)', () {
    test('drops entries and Author notes for absent people', () {
      final kept = _roster().retainingPeople({'ann', 'bo'});
      expect(kept.entries.map((e) => e.characterId), ['ann', 'bo']);
      expect(kept.authorNotes.map((n) => n.subjectCharacterId), ['ann']);
    });

    test('strips a dropped person from a shared-gear line, keeps the line for whoever remains', () {
      final kept = _roster().retainingPeople({'ann', 'bo'});
      final tent = kept.gear.firstWhere((g) => g.id == 'g1');
      expect(tent.assigneeIds, {'ann', 'bo'});
    });

    test('removes a gear/meal line left with nobody on it', () {
      final kept = _roster().retainingPeople({'ann', 'bo'});
      expect(kept.gear.map((g) => g.id), ['g1']); // g2 was cy-only
      expect(kept.meals.map((m) => m.id), ['m1', 'm2']); // m2 keeps ann
      expect(kept.meals.firstWhere((m) => m.id == 'm2').cookIds, {'ann'});
    });

    test('retainingPeople({}) empties the whole roster', () {
      expect(_roster().retainingPeople(const {}).isEmpty, isTrue);
    });

    test('day/passage group overrides are itinerary-keyed, not people-keyed — untouched', () {
      final kept = _roster().retainingPeople({'ann'});
      expect(kept.entries.single.dayGroupOverrides, {'d1': 'Slow'});
      expect(kept.entries.single.passageGroupOverrides, {'p1': 'Fast'});
    });
  });

  test('withoutPositionOverrides clears per-day/per-passage groups, keeps the trip-level group', () {
    final flat = _roster().withoutPositionOverrides();
    final ann = flat.entries.first;
    expect(ann.groupLabel, 'Fast');
    expect(ann.subgroupLabel, 'Scouts');
    expect(ann.dayGroupOverrides, isEmpty);
    expect(ann.passageGroupOverrides, isEmpty);
  });
}
