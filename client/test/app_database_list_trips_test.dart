// G2a (FR74a) — "a list surface shows title, modes, and last-edited,
// most-recent-first". `AppDatabase.listTrips()` is the projection that
// surface reads from; this pins its ordering and field shape directly,
// which the declared-modes-focused `app_database_declared_modes_test.dart`
// doesn't exercise.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';

void main() {
  test('listTrips returns entries most-recent-first with title/modes/updatedAt', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.saveTrip(
      id: 'oldest',
      title: 'Blue Ridge Traverse',
      modes: const ['hiking'],
      declaredModes: const ['hiking'],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 1),
    );
    await db.saveTrip(
      id: 'newest',
      title: 'Pisgah Loop',
      modes: const ['cycling', 'paddling'],
      declaredModes: const ['cycling', 'paddling'],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 25),
    );
    await db.saveTrip(
      id: 'middle',
      title: 'French Broad Paddle',
      modes: const ['paddling'],
      declaredModes: const ['paddling'],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 10),
    );

    final entries = await db.listTrips();

    expect(entries.map((e) => e.id).toList(), ['newest', 'middle', 'oldest']);

    final newest = entries.first;
    expect(newest.title, 'Pisgah Loop');
    expect(newest.modes, ['cycling', 'paddling']);
    // drift round-trips DateTime through a local-time representation, so
    // compare the moment rather than the exact UTC-vs-local rendering.
    expect(newest.updatedAt.isAtSameMomentAs(DateTime.utc(2026, 8, 25)), isTrue);
  });

  test('a trip with no realized modes lists with an empty modes list, not [""]', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.saveTrip(
      id: 'trip-1',
      title: 'Just Started',
      modes: const [],
      declaredModes: const ['hiking'],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 26),
    );

    final entries = await db.listTrips();
    expect(entries.single.modes, isEmpty);
  });

  test('re-saving bumps a trip to the top of the list', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.saveTrip(
      id: 'a',
      title: 'Trip A',
      modes: const [],
      declaredModes: const [],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 1),
    );
    await db.saveTrip(
      id: 'b',
      title: 'Trip B',
      modes: const [],
      declaredModes: const [],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 2),
    );
    expect((await db.listTrips()).map((e) => e.id).toList(), ['b', 'a']);

    await db.saveTrip(
      id: 'a',
      title: 'Trip A',
      modes: const [],
      declaredModes: const [],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 8, 3),
    );
    expect((await db.listTrips()).map((e) => e.id).toList(), ['a', 'b']);
  });
}
