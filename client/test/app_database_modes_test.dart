// FR144/N0, issue #319 — `Trip.modes` is persisted as its own drift column
// (`app_database.dart`'s doc comment on the column), alongside but never
// inside `payload`. This pins that round trip directly, plus the v6
// migration that folded the pre-#319 `modes` + `declared_modes` pair into
// the one column.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';

void main() {
  test('modes round-trips through save/load', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.saveTrip(
      id: 'trip-1',
      title: 'Test trip',
      modes: ['cycling', 'hiking'],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 26),
    );

    final row = await db.loadTrip('trip-1');
    expect(row, isNotNull);
    expect(row!.modes.split(',').toSet(), {'cycling', 'hiking'});
  });

  test('a row saved with no modes stores an empty string, not null', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.saveTrip(
      id: 'trip-1',
      title: 'Test trip',
      modes: const [],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 26),
    );

    final row = await db.loadTrip('trip-1');
    expect(row!.modes, '');
  });

  test('re-saving the same trip id updates its modes in place', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.saveTrip(
      id: 'trip-1',
      title: 'Test trip',
      modes: ['cycling'],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 26),
    );
    await db.saveTrip(
      id: 'trip-1',
      title: 'Test trip',
      modes: ['cycling', 'paddling'],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 26, 1),
    );

    final row = await db.loadTrip('trip-1');
    expect(row!.modes.split(',').toSet(), {'cycling', 'paddling'});
  });

  group('v6 migration (#319) — one mode set', () {
    /// A v5 file as the pre-#319 build wrote it: the `modes` column holding
    /// the segment-derived list and `declared_modes` the Author's set.
    NativeDatabase v5File(List<(String, String, String)> rows) => NativeDatabase.memory(
          setup: (raw) {
            raw.execute('''
              CREATE TABLE trips (
                id TEXT NOT NULL,
                title TEXT NOT NULL,
                modes TEXT NOT NULL,
                declared_modes TEXT NOT NULL DEFAULT '',
                payload TEXT NOT NULL,
                roster TEXT NOT NULL DEFAULT '',
                summary TEXT NOT NULL DEFAULT '{}',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (id)
              );
              CREATE TABLE settings_kv (key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (key));
              CREATE TABLE rejected_proposals (
                trip_id TEXT NOT NULL, proposal_id TEXT NOT NULL, rejected_at INTEGER NOT NULL,
                PRIMARY KEY (trip_id, proposal_id)
              );
            ''');
            for (final (id, modes, declared) in rows) {
              raw.execute(
                'INSERT INTO trips (id, title, modes, declared_modes, payload, created_at, updated_at) '
                'VALUES (?, ?, ?, ?, ?, 0, 0)',
                [id, 'Trip $id', modes, declared, '{}'],
              );
            }
            raw.execute('PRAGMA user_version = 5');
          },
        );

    test('folds declared + realised into `modes`, Author\'s order first, deduped', () async {
      final db = AppDatabase.forTesting(v5File([
        // Declared cycling+hiking, only cycling ridden so far.
        ('declared-wins', 'cycling', 'hiking,cycling'),
        // Pre-N0 row: nothing declared, two modes realised.
        ('pre-n0', 'paddling,driving', ''),
        // Realised a mode the Author never declared.
        ('undeclared-passage', 'driving', 'cycling'),
        // Brand-new, day-less, declared only.
        ('day-less', '', 'paddling'),
        // Both empty.
        ('empty', '', ''),
      ]));
      addTearDown(db.close);

      Future<List<String>> modesOf(String id) async =>
          (await db.loadTrip(id))!.modes.split(',').where((m) => m.isNotEmpty).toList();

      expect(await modesOf('declared-wins'), ['hiking', 'cycling']);
      expect(await modesOf('pre-n0'), ['paddling', 'driving']);
      expect(await modesOf('undeclared-passage'), ['cycling', 'driving']);
      expect(await modesOf('day-less'), ['paddling']);
      expect(await modesOf('empty'), isEmpty);
    });

    test('drops the `declared_modes` column and keeps every other one', () async {
      final db = AppDatabase.forTesting(v5File([('t', 'cycling', 'hiking')]));
      addTearDown(db.close);
      // Force the migration to run before we look at the schema.
      await db.loadTrip('t');

      final columns = (await db.customSelect('PRAGMA table_info(trips)').get())
          .map((r) => r.read<String>('name'))
          .toSet();
      expect(columns, isNot(contains('declared_modes')));
      expect(
        columns,
        containsAll(
            ['id', 'title', 'modes', 'payload', 'roster', 'summary', 'created_at', 'updated_at']),
      );
      final version =
          (await db.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version');
      expect(version, 6);
    });

    test('a v2 file (before the declared column ever existed) still migrates through', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory(setup: (raw) {
        raw.execute('''
          CREATE TABLE trips (
            id TEXT NOT NULL, title TEXT NOT NULL, modes TEXT NOT NULL, payload TEXT NOT NULL,
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY (id)
          );
          CREATE TABLE settings_kv (key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (key));
          CREATE TABLE rejected_proposals (
            trip_id TEXT NOT NULL, proposal_id TEXT NOT NULL, rejected_at INTEGER NOT NULL,
            PRIMARY KEY (trip_id, proposal_id)
          );
        ''');
        raw.execute(
          "INSERT INTO trips (id, title, modes, payload, created_at, updated_at) "
          "VALUES ('old', 'Old', 'mountain_biking,cycling', '{}', 0, 0)",
        );
        raw.execute('PRAGMA user_version = 2');
      }));
      addTearDown(db.close);

      final row = await db.loadTrip('old');
      // v5's #315 fold *and* v6's merge both applied.
      expect(row!.modes, 'cycling');
    });
  });
}
