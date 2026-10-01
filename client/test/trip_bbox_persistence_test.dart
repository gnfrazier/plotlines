// Issue #570 — `TripPersistence.open` reset the trip bbox on every reopen,
// so a reopened trip had no extent: candidates disabled, co-location
// unscoped, curation maps on the home region (#571/#572 were its symptoms).
// The bbox now rides in its own `Trips.bbox` column (ARCH D70, the D64
// pattern) and comes back on open.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/domain/clone.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

const _bbox = TripBbox(minLat: 36.0, minLon: -79.9, maxLat: 36.2, maxLon: -79.6);

ProviderContainer _container(AppDatabase db) {
  final c = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
  addTearDown(c.dispose);
  return c;
}

Future<String> _saveWith(ProviderContainer c, TripBbox? bbox) async {
  c.read(currentTripProvider.notifier).reset();
  if (bbox != null) c.read(tripBboxProvider.notifier).set(bbox);
  await c.read(tripPersistenceProvider).save();
  return c.read(currentTripProvider).id;
}

void main() {
  test('a saved trip reopens with its bbox, in a fresh session', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await _saveWith(_container(db), _bbox);

    final reader = _container(db);
    await reader.read(tripPersistenceProvider).open(id);

    expect(reader.read(tripBboxProvider), _bbox);
  });

  test('opening a trip with no bbox clears the previous trip\'s', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final c = _container(db);
    final undrawn = await _saveWith(c, null);
    c.read(tripBboxProvider.notifier).set(_bbox);

    await c.read(tripPersistenceProvider).open(undrawn);

    expect(c.read(tripBboxProvider), isNull);
  });

  test('a malformed stored bbox reads as not drawn, and the trip still opens', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final c = _container(db);
    final id = await _saveWith(c, _bbox);
    await db.customStatement("UPDATE trips SET bbox = '[1, 2]' WHERE id = ?", [id]);

    final reader = _container(db);
    await reader.read(tripPersistenceProvider).open(id);

    expect(reader.read(tripBboxProvider), isNull);
    expect(reader.read(currentTripProvider).id, id);
  });

  test('a whole-trip clone carries the bbox; a roster-only clone does not', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final c = _container(db);
    final id = await _saveWith(c, _bbox);

    final whole = await c.read(tripPersistenceProvider).clone(id, CloneScope.wholeTrip);
    final roster = await c.read(tripPersistenceProvider).clone(id, CloneScope.rosterOnly);

    expect((await db.loadTrip(whole.trip.id))!.bbox, isNotEmpty);
    expect((await db.loadTrip(roster.trip.id))!.bbox, isEmpty);
  });

  test('a v6 file migrates to v7 with every trip "not drawn yet"', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory(setup: (raw) {
      raw.execute('''
        CREATE TABLE trips (
          id TEXT NOT NULL, title TEXT NOT NULL, modes TEXT NOT NULL, payload TEXT NOT NULL,
          roster TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL DEFAULT '{}',
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY (id)
        );
        CREATE TABLE settings_kv (key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (key));
        CREATE TABLE rejected_proposals (
          trip_id TEXT NOT NULL, proposal_id TEXT NOT NULL, rejected_at INTEGER NOT NULL,
          PRIMARY KEY (trip_id, proposal_id)
        );
      ''');
      raw.execute("INSERT INTO trips (id, title, modes, payload, created_at, updated_at) "
          "VALUES ('old', 'Old', 'cycling', '{}', 0, 0)");
      raw.execute('PRAGMA user_version = 6');
    }));
    addTearDown(db.close);

    final row = await db.loadTrip('old');
    expect(row!.bbox, '');
    final version =
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version');
    expect(version, 7);
  });
}
