// FR144/N0, issue #319 — `Trip.modes`: the trip's one stored mode set, and
// deliberately absent from the wire payload (`trip_payload.schema.json` is
// `additionalProperties: false` and has no such field — see `trip.dart`'s
// doc comment on `modes`).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

Trip _trip({Set<String> modes = const {}, List<Day> days = const []}) => Trip(
      id: 'trip-1',
      title: 'Test trip',
      createdAt: '2026-08-26T00:00:00Z',
      updatedAt: '2026-08-26T00:00:00Z',
      days: days,
      modes: modes,
    );

void main() {
  test('defaults to empty for a brand-new trip', () {
    expect(_trip().modes, isEmpty);
  });

  test('is the stored set, never derived from the segments', () {
    // #319 — there is no second, segment-derived list any more. What the
    // segments use is folded *into* this set by `CurrentTripNotifier`
    // (`_replaceDay`) and `TripPersistence.open`; the domain object itself
    // just holds what it was given.
    final trip = _trip(
      modes: {'hiking'},
      days: [
        Day(id: 'day-1', index: 1, segments: [
          Segment(id: 'seg-1', mode: 'cycling', shape: 'point_to_point',
              start: const [-105.2, 40.0], end: const [-105.1, 40.1]),
        ]),
      ],
    );
    expect(trip.modes, {'hiking'});
  });

  test('copyWith replaces modes; omitting it preserves the current set', () {
    final trip = _trip(modes: {'cycling'});
    final widened = trip.copyWith(modes: {'cycling', 'hiking'});
    expect(widened.modes, {'cycling', 'hiking'});

    final untouched = widened.copyWith(title: 'Renamed');
    expect(untouched.modes, {'cycling', 'hiking'});
  });

  test('never appears in toJson, and fromJson never invents it from the payload', () {
    final trip = _trip(modes: {'cycling', 'paddling'});
    final json = trip.toJson();
    expect(json.containsKey('modes'), isFalse);
    expect(json.containsKey('declared_modes'), isFalse);

    // fromJson has no source for it in the payload — always empty, by
    // design (`current_trip_provider.dart`'s `TripPersistence.open` is
    // what re-attaches it, from its own drift column, after this call).
    final roundTripped = Trip.fromJson(json);
    expect(roundTripped.modes, isEmpty);
  });
}
