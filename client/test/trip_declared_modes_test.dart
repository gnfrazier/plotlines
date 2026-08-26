// FR144/N0 — `Trip.declaredModes`: the Author's stated set, distinct from
// the derived `Trip.modes` getter, and deliberately absent from the wire
// payload (`trip_payload.schema.json` is `additionalProperties: false` and
// has no such field — see `trip.dart`'s doc comment on `declaredModes`).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

Trip _trip({Set<String> declaredModes = const {}, List<Day> days = const []}) => Trip(
      id: 'trip-1',
      title: 'Test trip',
      createdAt: '2026-08-26T00:00:00Z',
      updatedAt: '2026-08-26T00:00:00Z',
      days: days,
      declaredModes: declaredModes,
    );

void main() {
  test('defaults to empty for a brand-new trip', () {
    expect(_trip().declaredModes, isEmpty);
  });

  test('is independent of the derived modes getter', () {
    // A trip can declare hiking while nothing hiking has been ridden yet
    // (a fresh day-less trip) — `modes` (derived) and `declaredModes`
    // (stated) must not be conflated.
    final trip = _trip(
      declaredModes: {'hiking'},
      days: [
        Day(id: 'day-1', index: 1, segments: [
          Segment(id: 'seg-1', mode: 'cycling', shape: 'point_to_point',
              start: const [-105.2, 40.0], end: const [-105.1, 40.1]),
        ]),
      ],
    );
    expect(trip.declaredModes, {'hiking'});
    expect(trip.modes, {'cycling'});
  });

  test('copyWith replaces declaredModes; omitting it preserves the current set', () {
    final trip = _trip(declaredModes: {'cycling'});
    final widened = trip.copyWith(declaredModes: {'cycling', 'hiking'});
    expect(widened.declaredModes, {'cycling', 'hiking'});

    final untouched = widened.copyWith(title: 'Renamed');
    expect(untouched.declaredModes, {'cycling', 'hiking'});
  });

  test('never appears in toJson, and fromJson never invents it from the payload', () {
    final trip = _trip(declaredModes: {'cycling', 'paddling'});
    final json = trip.toJson();
    expect(json.containsKey('declared_modes'), isFalse);
    expect(json.containsKey('declaredModes'), isFalse);

    // fromJson has no source for it in the payload — always empty, by
    // design (`current_trip_provider.dart`'s `TripPersistence.open` is
    // what re-attaches it, from its own drift column, after this call).
    final roundTripped = Trip.fromJson(json);
    expect(roundTripped.declaredModes, isEmpty);
  });
}
