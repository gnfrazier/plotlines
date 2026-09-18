// FR144/N0, issue #319 — the full save/reopen path: `Trip.modes` isn't part
// of `payload` (`trip.dart`'s doc comment), so `TripPersistence` has to
// shuttle it through its own drift column instead. This is the integration
// point `app_database_modes_test.dart` (raw column round trip) and
// `trip_modes_test.dart` (domain object shape) don't individually cover.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';

void main() {
  test('a saved trip\'s modes survive reopening in a fresh container', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final writer = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(writer.dispose);
    writer.read(currentTripProvider.notifier).setModes({'hiking', 'paddling'});
    final tripId = writer.read(currentTripProvider).id;
    await writer.read(tripPersistenceProvider).save();

    // A fresh container — nothing carries over except what actually persisted.
    final reader = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(reader.dispose);
    await reader.read(tripPersistenceProvider).open(tripId);

    expect(reader.read(currentTripProvider).modes, {'hiking', 'paddling'});
  });

  test('a day-less trip reopens with exactly the set it saved — nothing invented, nothing lost',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final writer = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(writer.dispose);
    writer.read(currentTripProvider.notifier).setModes({'cycling'});
    final tripId = writer.read(currentTripProvider).id;
    await writer.read(tripPersistenceProvider).save();

    final reader = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(reader.dispose);
    await reader.read(tripPersistenceProvider).open(tripId);

    expect(reader.read(currentTripProvider).days, isEmpty);
    expect(reader.read(currentTripProvider).modes, {'cycling'});
  });

  test('#319 — a row whose payload carries a segment mode outside its stored set '
      'reopens with the set widened, so the picker can always show the passage', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // Written directly, the way a build in between #315 and #319 (or an
    // imported payload) could have left it: the column says cycling, the
    // payload has a hiking passage.
    final trip = Trip(
      id: 'trip-1',
      title: 'Test trip',
      createdAt: '2026-09-18T00:00:00Z',
      updatedAt: '2026-09-18T00:00:00Z',
      days: [
        Day(id: 'day-1', index: 1, segments: [
          Segment(id: 'seg-1', mode: 'hiking', shape: 'point_to_point',
              start: const [-105.2, 40.0], end: const [-105.1, 40.1]),
        ]),
      ],
    );
    await db.saveTrip(
      id: trip.id,
      title: trip.title,
      modes: ['cycling'],
      payloadJson: jsonEncode(trip.toJson()),
      updatedAt: DateTime.utc(2026, 9, 18),
    );

    final reader = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(reader.dispose);
    await reader.read(tripPersistenceProvider).open('trip-1');

    expect(reader.read(currentTripProvider).modes, {'cycling', 'hiking'});
  });
}
