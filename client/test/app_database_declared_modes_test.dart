// FR144/N0 — `declaredModes` is persisted as its own drift column
// (`app_database.dart`'s doc comment on the column), alongside but never
// inside `payload`. This pins that round trip directly, plus the
// pre-N0-row fallback the migration note describes.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';

void main() {
  test('declaredModes round-trips through save/load, independent of modes', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.saveTrip(
      id: 'trip-1',
      title: 'Test trip',
      modes: ['cycling'], // realized modes — deliberately different
      declaredModes: ['cycling', 'hiking'],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 26),
    );

    final row = await db.loadTrip('trip-1');
    expect(row, isNotNull);
    expect(row!.modes.split(','), ['cycling']);
    expect(row.declaredModes.split(',').toSet(), {'cycling', 'hiking'});
  });

  test('a row saved with no declared modes stores an empty string, not null', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.saveTrip(
      id: 'trip-1',
      title: 'Test trip',
      modes: const [],
      declaredModes: const [],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 26),
    );

    final row = await db.loadTrip('trip-1');
    expect(row!.declaredModes, '');
  });

  test('re-saving the same trip id updates its declared modes in place', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.saveTrip(
      id: 'trip-1',
      title: 'Test trip',
      modes: const [],
      declaredModes: ['cycling'],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 26),
    );
    await db.saveTrip(
      id: 'trip-1',
      title: 'Test trip',
      modes: const [],
      declaredModes: ['cycling', 'paddling'],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 26, 1),
    );

    final row = await db.loadTrip('trip-1');
    expect(row!.declaredModes.split(',').toSet(), {'cycling', 'paddling'});
  });
}
