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
        GearItem(id: 'g1', label: 'Tent', shared: true, assigneeIds: {'ann', 'bo'}),
        GearItem(id: 'g2', label: 'Stove', shared: true, assigneeIds: {'cy'}),
        GearItem(
          id: 'g3',
          label: 'Headlamp',
          necessity: GearNecessity.mandatory,
          scope: GearScope.mode('hiking'),
        ),
        GearItem(
          id: 'g4',
          label: 'Helmet',
          necessity: GearNecessity.mandatory,
          scope: GearScope.stationActivity('climbing'),
        ),
      ],
      meals: [
        MealResponsibility(id: 'm1', label: 'Night 1 dinner', dayId: 'd1', cookIds: {'bo'}),
        MealResponsibility(id: 'm2', label: 'Night 2 dinner', cookIds: {'ann', 'cy'}),
      ],
      authorNotes: [
        AuthorNote(subjectCharacterId: 'ann', body: 'Strong on scrambly ground.', updatedAt: '2024-06-01T00:00:00.000Z'),
        AuthorNote(subjectCharacterId: 'cy', body: 'New to multi-day.', updatedAt: '2025-01-15T00:00:00.000Z'),
      ],
      authorEnteredValues: [
        AuthorEnteredValue(
          subjectCharacterId: 'ann',
          fieldId: 'phone',
          value: '555-0100',
          updatedAt: '2025-06-01T00:00:00.000Z',
        ),
        AuthorEnteredValue(
          subjectCharacterId: 'cy',
          fieldId: 'emergency_contact',
          value: 'Dana, 555-0199',
          updatedAt: '2025-06-02T00:00:00.000Z',
        ),
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
    expect(after.gear.map((g) => g.id), ['g1', 'g2', 'g3', 'g4']);
    expect(after.gear.first.shared, isTrue);
    expect(after.gear.first.assigneeIds, {'ann', 'bo'});
    // C8 — necessity and scope round-trip too.
    final headlamp = after.gear.firstWhere((g) => g.id == 'g3');
    expect(headlamp.shared, isFalse);
    expect(headlamp.necessity, GearNecessity.mandatory);
    expect(headlamp.scope.kind, GearScopeKind.mode);
    expect(headlamp.scope.key, 'hiking');
    final helmet = after.gear.firstWhere((g) => g.id == 'g4');
    expect(helmet.scope.kind, GearScopeKind.stationActivity);
    expect(helmet.scope.key, 'climbing');
    expect(after.meals.firstWhere((m) => m.id == 'm1').dayId, 'd1');
    expect(after.authorNotes.map((n) => n.subjectCharacterId), ['ann', 'cy']);
    expect(after.authorNotes.first.updatedAt, '2024-06-01T00:00:00.000Z');
    // D4b (FR78a) — author-entered values round-trip with zero loss too.
    expect(after.authorEnteredValues.map((v) => v.fieldId), ['phone', 'emergency_contact']);
    expect(after.authorEnteredValues.first.value, '555-0100');
    expect(after.authorEnteredValues.first.updatedAt, '2025-06-01T00:00:00.000Z');
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

    test('drops author-entered values for absent people (FR74b / D6a)', () {
      final kept = _roster().retainingPeople({'ann', 'bo'});
      expect(kept.authorEnteredValues.map((v) => v.subjectCharacterId), ['ann']);
      // cy is gone, so is the value the Author entered about cy.
      expect(kept.authorEnteredValues.any((v) => v.subjectCharacterId == 'cy'), isFalse);
    });

    test('strips a dropped person from a shared-gear line, keeps the line for whoever remains', () {
      final kept = _roster().retainingPeople({'ann', 'bo'});
      final tent = kept.gear.firstWhere((g) => g.id == 'g1');
      expect(tent.assigneeIds, {'ann', 'bo'});
    });

    test('drops a shared-gear line orphaned of all its people, keeps personal-list lines (C8)', () {
      final kept = _roster().retainingPeople({'ann', 'bo'});
      // g2 was a shared line assigned only to cy — nothing to dangle, so it
      // drops. g3/g4 are personal-list lines keyed to nobody — always kept.
      expect(kept.gear.map((g) => g.id), ['g1', 'g3', 'g4']);
      expect(kept.meals.map((m) => m.id), ['m1', 'm2']); // m2 keeps ann
      expect(kept.meals.firstWhere((m) => m.id == 'm2').cookIds, {'ann'});
    });

    test('retainingPeople({}) drops every people-keyed line, keeps the personal-list gear', () {
      final kept = _roster().retainingPeople(const {});
      expect(kept.entries, isEmpty);
      expect(kept.meals, isEmpty);
      expect(kept.authorNotes, isEmpty);
      expect(kept.authorEnteredValues, isEmpty);
      // The mode/activity checklist is not keyed to a person — it survives.
      expect(kept.gear.map((g) => g.id), ['g3', 'g4']);
    });

    test('withoutPositionOverrides keeps author-entered values untouched', () {
      final flat = _roster().withoutPositionOverrides();
      expect(flat.authorEnteredValues.map((v) => v.fieldId), ['phone', 'emergency_contact']);
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

  group('GearItem (C8 / FR24)', () {
    test('a trip-scoped recommended personal item omits its defaults from JSON', () {
      const item = GearItem(id: 'x', label: 'Sunscreen');
      expect(item.toJson(), {'id': 'x', 'label': 'Sunscreen', 'necessity': 'recommended'});
      final back = GearItem.fromJson(item.toJson());
      expect(back.scope, const GearScope.trip());
      expect(back.necessity, GearNecessity.recommended);
      expect(back.shared, isFalse);
    });

    test('a scoped, shared, mandatory item round-trips every field', () {
      final item = GearItem(
        id: 'y',
        label: 'Rope',
        scope: GearScope.stationActivity('climbing'),
        necessity: GearNecessity.mandatory,
        shared: true,
        assigneeIds: const {'ann'},
      );
      final back = GearItem.fromJson(item.toJson());
      expect(back.scope, GearScope.stationActivity('climbing'));
      expect(back.isMandatory, isTrue);
      expect(back.shared, isTrue);
      expect(back.assigneeIds, {'ann'});
    });

    test('a pre-C8 assignment shape (no `shared`, has assignees) reads as shared', () {
      final back = GearItem.fromJson({
        'id': 'g1',
        'label': 'Tent',
        'assignee_ids': ['ann', 'bo'],
      });
      expect(back.shared, isTrue);
      expect(back.assigneeIds, {'ann', 'bo'});
      expect(back.scope, const GearScope.trip());
      expect(back.necessity, GearNecessity.recommended);
    });

    test('turning shared off via copyWith is the caller\'s to pair with clearing assignees', () {
      final shared = GearItem(id: 'z', label: 'Stove', shared: true, assigneeIds: const {'ann'});
      // copyWith is literal — it does not infer. The provider does the pairing.
      expect(shared.copyWith(shared: false).assigneeIds, {'ann'});
    });
  });
}
