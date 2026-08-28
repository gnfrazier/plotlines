// FR74 / FR74b (G2, G2b) — the `Trips.roster` and `Trips.summary` columns
// added beside `payload` (schema v4). `roster` carries `TripRoster.toJson()`;
// `summary` carries the denormalized card-face metrics the Trip Library grid
// reads without decoding a payload per row. Pins their round trip and the
// old-row defaults the migration relies on, matching the style of
// `app_database_declared_modes_test.dart`.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';

void main() {
  test('roster + summary JSON round-trip through save/load, beside payload', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.saveTrip(
      id: 'trip-1',
      title: 'Test trip',
      modes: const ['hiking'],
      declaredModes: const ['hiking'],
      payloadJson: '{"schema_version":"1.4.0"}',
      rosterJson: '{"entries":[{"character_id":"ann","name":"Ann"}]}',
      summaryJson: '{"distance_m":42000,"day_count":3,"group_size":1}',
      updatedAt: DateTime.utc(2026, 8, 26),
    );

    final row = await db.loadTrip('trip-1');
    expect(row!.payload, '{"schema_version":"1.4.0"}');
    expect(row.roster, contains('"character_id":"ann"'));
    expect(row.summary, contains('"day_count":3'));
  });

  test('a row saved without roster/summary stores the empty defaults', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.saveTrip(
      id: 'trip-1',
      title: 'Bare',
      modes: const [],
      declaredModes: const [],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 26),
    );

    final row = await db.loadTrip('trip-1');
    expect(row!.roster, '');
    expect(row.summary, '{}');
  });

  test('listTrips projects the summary metrics and a This-device sync badge', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.saveTrip(
      id: 'with-metrics',
      title: 'Pisgah Loop',
      modes: const ['cycling'],
      declaredModes: const ['cycling', 'gravel'],
      payloadJson: '{}',
      summaryJson: '{"distance_m":58000,"ascent_m":1200,"day_count":2,"variant_count":0,"group_size":4}',
      updatedAt: DateTime.utc(2026, 8, 27),
    );

    final entry = (await db.listTrips()).single;
    expect(entry.summary.distanceM, 58000);
    expect(entry.summary.ascentM, 1200);
    expect(entry.summary.dayCount, 2);
    expect(entry.summary.groupSize, 4);
    expect(entry.syncBadge, TripSyncBadge.thisDevice);
    // FR74's "filter by mode" matches realised OR declared modes.
    expect(entry.allModes, {'cycling', 'gravel'});
  });

  test('listTrips tolerates a legacy empty summary string', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.saveTrip(
      id: 'legacy',
      title: 'Old trip',
      modes: const [],
      declaredModes: const [],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 20),
    );

    final entry = (await db.listTrips()).single;
    expect(entry.summary.distanceM, isNull);
    expect(entry.summary.dayCount, isNull);
  });
}
