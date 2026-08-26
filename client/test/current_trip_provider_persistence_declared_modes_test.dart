// FR144/N0 — the full save/reopen path: `declaredModes` isn't part of
// `payload` (`trip.dart`'s doc comment), so `TripPersistence` has to shuttle
// it through its own drift column instead. This is the integration point
// `app_database_declared_modes_test.dart` (raw column round trip) and
// `trip_declared_modes_test.dart` (domain object shape) don't individually
// cover.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';

void main() {
  test('a saved trip\'s declared modes survive reopening in a fresh container', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final writer = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(writer.dispose);
    writer.read(currentTripProvider.notifier).setDeclaredModes({'hiking', 'paddling'});
    final tripId = writer.read(currentTripProvider).id;
    await writer.read(tripPersistenceProvider).save();

    // A fresh container — nothing carries over except what actually persisted.
    final reader = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(reader.dispose);
    await reader.read(tripPersistenceProvider).open(tripId);

    expect(reader.read(currentTripProvider).declaredModes, {'hiking', 'paddling'});
  });

  test('reopening never invents declared modes from the payload\'s realized segments', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final writer = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(writer.dispose);
    writer.read(currentTripProvider.notifier).setDeclaredModes({'cycling'});
    final tripId = writer.read(currentTripProvider).id;
    await writer.read(tripPersistenceProvider).save();

    final reader = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(reader.dispose);
    await reader.read(tripPersistenceProvider).open(tripId);

    // No days/segments were ever added, so `modes` (derived) is empty —
    // reopening must not blur that together with `declaredModes`.
    expect(reader.read(currentTripProvider).modes, isEmpty);
    expect(reader.read(currentTripProvider).declaredModes, {'cycling'});
  });
}
