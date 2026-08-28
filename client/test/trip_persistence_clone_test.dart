// FR74 / FR74b (G2, G2b) — `TripPersistence.clone` and `.adopt`: the clone
// domain function wired to drift storage. Covers that a clone is persisted as
// a new row, that the library list is invalidated, that the roster column and
// the card-summary column are written for the clone, and the roster-only vs
// authored-trip-only vs whole-trip shapes end to end.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/domain/clone.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_roster_provider.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';

ProviderContainer _container(AppDatabase db) {
  final c = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
  addTearDown(c.dispose);
  return c;
}

/// Seeds a saved trip with two days, a roster of two, and one gear line.
Future<String> _seedTrip(ProviderContainer c) async {
  final notifier = c.read(currentTripProvider.notifier);
  notifier.reset();
  notifier.setDeclaredModes({'hiking'});
  notifier.renameTrip('Blue Ridge Traverse');
  notifier.addBlankDay();
  notifier.addBlankDay();
  c.read(currentRosterProvider.notifier).open(const TripRoster(
        entries: [
          RosterEntry(characterId: 'ann', name: 'Ann', groupLabel: 'Fast'),
          RosterEntry(characterId: 'bo', name: 'Bo', groupLabel: 'Slow'),
        ],
        gear: [GearAssignment(id: 'g1', label: 'Tent', assigneeIds: {'ann', 'bo'})],
        authorNotes: [
          AuthorNote(subjectCharacterId: 'ann', body: 'Strong scrambler.', updatedAt: '2024-06-01T00:00:00.000Z'),
        ],
      ));
  final id = c.read(currentTripProvider).id;
  await c.read(tripPersistenceProvider).save();
  return id;
}

void main() {
  test('whole-trip clone is a new row carrying payload + roster, source untouched', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final c = _container(db);

    final srcId = await _seedTrip(c);
    final before = await db.listTrips();
    expect(before, hasLength(1));

    final outcome = await c.read(tripPersistenceProvider).clone(srcId, CloneScope.wholeTrip);

    final after = await db.listTrips();
    expect(after, hasLength(2));
    expect(outcome.trip.id, isNot(srcId));
    expect(outcome.runsTripInitiation, isFalse);

    // The clone's own row round-trips the roster.
    final freshReader = _container(db);
    await freshReader.read(tripPersistenceProvider).open(outcome.trip.id);
    expect(freshReader.read(currentTripProvider).days, hasLength(2));
    expect(freshReader.read(currentTripProvider).declaredModes, {'hiking'});
    final roster = freshReader.read(currentRosterProvider);
    expect(roster.entries.map((e) => e.characterId), ['ann', 'bo']);
    expect(roster.gear.single.assigneeIds, {'ann', 'bo'});
    expect(roster.authorNotes.single.updatedAt, '2024-06-01T00:00:00.000Z');

    // Source row unchanged.
    final srcReader = _container(db);
    await srcReader.read(tripPersistenceProvider).open(srcId);
    expect(srcReader.read(currentTripProvider).days, hasLength(2));
  });

  test('roster-only clone stores no days, keeps the roster, and reports trip initiation', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final c = _container(db);
    final srcId = await _seedTrip(c);

    final outcome = await c.read(tripPersistenceProvider).clone(srcId, CloneScope.rosterOnly);
    expect(outcome.runsTripInitiation, isTrue);

    final reader = _container(db);
    await reader.read(tripPersistenceProvider).open(outcome.trip.id);
    expect(reader.read(currentTripProvider).days, isEmpty);
    expect(reader.read(currentTripProvider).declaredModes, isEmpty);
    expect(reader.read(currentRosterProvider).entries, hasLength(2));

    // The card summary reflects the carried group size and the empty itinerary.
    final entry = (await db.listTrips()).firstWhere((t) => t.id == outcome.trip.id);
    expect(entry.summary.groupSize, 2);
    expect(entry.summary.dayCount, 0);
  });

  test('authored-trip-only clone stores the itinerary with an empty roster', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final c = _container(db);
    final srcId = await _seedTrip(c);

    final outcome =
        await c.read(tripPersistenceProvider).clone(srcId, CloneScope.authoredTripOnly);

    final reader = _container(db);
    await reader.read(tripPersistenceProvider).open(outcome.trip.id);
    expect(reader.read(currentTripProvider).days, hasLength(2));
    expect(reader.read(currentRosterProvider).isEmpty, isTrue);

    final entry = (await db.listTrips()).firstWhere((t) => t.id == outcome.trip.id);
    expect(entry.summary.groupSize, 0);
    expect(entry.summary.dayCount, 2);
  });

  test('clone of a missing trip id throws', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final c = _container(db);
    expect(
      () => c.read(tripPersistenceProvider).clone('nope', CloneScope.wholeTrip),
      throwsA(isA<StateError>()),
    );
  });

  test('adopt opens a clone outcome into the planner without a re-save', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final c = _container(db);
    final srcId = await _seedTrip(c);
    final outcome = await c.read(tripPersistenceProvider).clone(srcId, CloneScope.wholeTrip);

    c.read(tripPersistenceProvider).adopt(outcome);
    expect(c.read(currentTripProvider).id, outcome.trip.id);
    expect(c.read(currentTripProvider).declaredModes, {'hiking'});
    expect(c.read(currentRosterProvider).entries, hasLength(2));
  });
}
