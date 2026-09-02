// #235 B4 — the Dart half of the trip-payload contract.
//
// 22 of ~40 `fromJson`/`toJson` implementations in `lib/domain/` were never
// executed by any test: all six in `band.dart` (Band, Violation,
// TargetDistance), `Attribution` and `Provenance`, `Portage` and
// `SolveProvenance`, `Elevation` and `LimitBreach`, `CueSheet`,
// `ScheduledWindow`, `Relaxation`, `DayLimit`.
//
// That matters more here than a coverage number usually would, because
// `JsonFields.done()` throws on any key nobody read. It is a good design — it
// makes the schema's `additionalProperties: false` true at the reader — but its
// corollary is that an unexercised `fromJson` is a latent runtime crash the
// first time `plotlines_core.trips.payload` grows a field. CI's payload-schema
// job does not cover this: by its own comment it is "the light half of the
// spike: no graph fixtures, no Dart, no network", so the schema was gated
// against Python only.
//
// The oracle is round-trip identity against the *committed* SPIKE-20 payloads,
// which is stronger than either direction alone:
//
//   * `Trip.fromJson` reading them proves the domain layer can consume what
//     core actually emits — `done()` turns any unread field into a failure;
//   * `toJson` matching the input byte-for-structure proves nothing was
//     silently dropped on the way back out.
//
// Reading the fixtures where they live, rather than copying them under
// `test/`, is deliberate: a copy would drift from the payloads the Python gate
// validates, and drift is the whole thing this is here to catch.

library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

/// The committed SPIKE-20 payloads — the same three `spikes/SPIKE-20/run.py
/// --check-committed` validates against `docs/schemas/trip_payload.schema.json`
/// in CI.
final Directory _fixtures =
    Directory('${Directory.current.path}/../spikes/SPIKE-20/results/fixtures');

const List<String> _committedTrips = [
  'boulder_trip.json',
  'davis_trip.json',
  'viroqua_trip.json',
];

Map<String, dynamic> _load(String name) =>
    jsonDecode(File('${_fixtures.path}/$name').readAsStringSync())
        as Map<String, dynamic>;

/// JSON comparison that treats `4` and `4.0` as the same number.
///
/// Python's `round(x)` returns an `int` where a `float` was meant, which is
/// exactly why `JsonFields` reads every fractional value through `num` rather
/// than `as double`. Re-emitting `4` as `4.0` is faithful, not a drop, so the
/// comparison has to agree.
///
/// [exact] controls what happens to a key the output has and the input does
/// not. Loss is always a failure; *gain* is only a failure under [exact],
/// because a reader is allowed to materialise a schema default it just applied
/// — see `alternate.intent` and the test that names it. The round trip is
/// checked loosely once and exactly on the second pass, where nothing new may
/// appear.
void _expectSameJson(dynamic actual, dynamic expected, String path,
    {bool exact = true}) {
  if (expected is Map) {
    expect(actual, isA<Map>(), reason: 'at $path: expected an object');
    final a = actual as Map;
    final missing = expected.keys.toSet().difference(a.keys.toSet());
    expect(missing, isEmpty,
        reason: 'at $path: the round trip dropped $missing');
    if (exact) {
      expect(a.keys.toSet().difference(expected.keys.toSet()), isEmpty,
          reason: 'at $path: the round trip invented a field');
    }
    for (final key in expected.keys) {
      _expectSameJson(a[key], expected[key], '$path.$key', exact: exact);
    }
  } else if (expected is List) {
    expect(actual, isA<List>(), reason: 'at $path: expected an array');
    final a = actual as List;
    expect(a.length, expected.length, reason: 'at $path: length differs');
    for (var i = 0; i < expected.length; i++) {
      _expectSameJson(a[i], expected[i], '$path[$i]', exact: exact);
    }
  } else if (expected is num) {
    expect(actual, isA<num>(), reason: 'at $path: expected a number');
    expect((actual as num).toDouble(), closeTo(expected.toDouble(), 1e-9),
        reason: 'at $path');
  } else {
    expect(actual, expected, reason: 'at $path');
  }
}

void main() {
  group('the committed SPIKE-20 payloads', () {
    setUpAll(() {
      if (!_fixtures.existsSync()) {
        fail('SPIKE-20 fixtures not found at ${_fixtures.path} — this test is '
            'the Dart half of the payload gate and must not silently skip');
      }
    });

    for (final name in _committedTrips) {
      test('$name is readable by the domain layer', () {
        final trip = Trip.fromJson(_load(name));

        expect(trip.id, isNotEmpty);
        expect(trip.title, isNotEmpty);
        expect(trip.days, isNotEmpty);
        expect(trip.schemaVersion, isNotEmpty);
      });

      test('$name round-trips through fromJson/toJson without losing a field',
          () {
        final original = _load(name);

        _expectSameJson(Trip.fromJson(original).toJson(), original, name,
            exact: false);
      });

      test('$name re-reads what the domain layer wrote', () {
        // The second pass is what catches a codec that is lossy in a way the
        // first pass papers over — a field read into a variable and never
        // written back reads clean once and vanishes on the round trip.
        final once = Trip.fromJson(_load(name)).toJson();

        _expectSameJson(Trip.fromJson(once).toJson(), once, name);
      });
    }

    test('the only field the round trip adds is a schema default it applied',
        () {
      // The loose pass above allows the output to gain keys. This is the
      // audit of what it actually gains, so "allowed" does not quietly become
      // "unchecked".
      //
      // Today there is exactly one: `alternate.intent`, whose schema entry
      // reads "Absent means `accommodation` — a v1.0 payload that predates the
      // amendment reads as the fitness ladder it was". The committed fixtures
      // are from before that amendment, so reading them applies the default and
      // writing them back materialises it. That is the defaulting rule working,
      // not a codec inventing data.
      final added = <String>{};
      void diff(dynamic out, dynamic src, String path) {
        if (src is Map && out is Map) {
          added.addAll(out.keys.toSet().difference(src.keys.toSet()).cast<String>());
          for (final key in src.keys) {
            diff(out[key], src[key], '$path.$key');
          }
        } else if (src is List && out is List) {
          for (var i = 0; i < src.length && i < out.length; i++) {
            diff(out[i], src[i], '$path[$i]');
          }
        }
      }

      for (final name in _committedTrips) {
        final original = _load(name);
        diff(Trip.fromJson(original).toJson(), original, name);
      }

      expect(added, {'intent'},
          reason: 'the round trip added fields beyond the known schema default');
    });

    test('an alternate with no intent reads as accommodation', () {
      final trip = Trip.fromJson(_load('boulder_trip.json'));
      final alternates =
          trip.days.expand((d) => d.segments).expand((s) => s.alternates);

      expect(alternates, isNotEmpty);
      expect(alternates.map((a) => a.intent).toSet(), {'accommodation'});
    });

    test('every committed payload exercises the codecs the review named', () {
      // Guards the guard: if a future fixture rebuild drops portages or
      // attribution, these tests would keep passing while covering less. The
      // list is exactly the set of previously-unexercised codecs that the
      // committed payloads do reach.
      final seen = <String>{};
      void walk(dynamic node) {
        if (node is Map) {
          for (final entry in node.entries) {
            seen.add(entry.key as String);
            walk(entry.value);
          }
        } else if (node is List) {
          node.forEach(walk);
        }
      }

      for (final name in _committedTrips) {
        walk(_load(name));
      }

      for (final key in const [
        'bands', 'violations', 'target_distance', // band.dart
        'attribution', 'provenance', //              trip.dart
        'portages', 'solve', //                      segment.dart
        'elevation', 'limit_breaches', //            route_metrics.dart
        'cue_sheet', 'derived_from', //              cue.dart
        'scheduled', 'narration', 'media', //        node.dart
        'alternates', 'transitions',
      ]) {
        expect(seen, contains(key),
            reason: 'no committed payload carries `$key` any more — the '
                'round-trip no longer covers its codec');
      }
    });
  });

  group('codecs the committed payloads do not reach', () {
    test('a day-limit map round-trips', () {
      // `trip.defaults.day_limits` and `day.limits` are the one shape absent
      // from all three fixtures, so `DayLimit` gets its own case rather than
      // going untested.
      final json = {
        'schema_version': '2.0',
        'id': 't1',
        'title': 'Limits',
        'created_at': '2026-09-02T00:00:00Z',
        'updated_at': '2026-09-02T00:00:00Z',
        'defaults': {
          'day_limits': {
            'cycling': {'min_m': 10000.0, 'max_m': 90000.0},
            'hiking': {'max_m': 25000.0},
          },
        },
        'days': <Map<String, dynamic>>[],
      };

      final trip = Trip.fromJson(Map<String, dynamic>.from(json));

      expect(trip.dayLimits.keys, containsAll(['cycling', 'hiking']));
      expect(trip.dayLimits['cycling']!.minM, 10000.0);
      expect(trip.dayLimits['cycling']!.maxM, 90000.0);
      expect(trip.dayLimits['hiking']!.minM, isNull);
      _expectSameJson(trip.toJson(), json, 'day_limits trip');
    });

    test('a diagnosis with relaxations round-trips', () {
      // A6 / FR9's conflict payload travels on `/segments/diagnose`, not inside
      // a trip, so no trip fixture reaches `Relaxation`.
      final json = {
        'feasible': false,
        'kind': 'band_conflict',
        'conflict': ['climb_m', 'distance_m'],
        'explanation': 'climb_m cannot be met inside the distance band',
        'via_implicated': true,
        'via_relaxation': {'drop': 'via-2'},
        'distance_advisory': true,
        'advisory_deviation': {'realised_m': 41200.0, 'target_m': 40000.0},
        'relaxations': [
          {
            'metric': 'climb_m',
            // Human-readable band descriptions (`Band.describe()` on the
            // Python side), not numbers — the UI renders them verbatim.
            'from': 'at least 600 m',
            'to': 'at least 420 m',
            'reached_by': 'quiet',
            'trade_off': 'more traffic',
          },
        ],
        'envelope': {
          'climb_m': [180.0, 430.0],
          'distance_m': [38000.0, 44000.0],
        },
        'solves': 12,
        'elapsed_ms': 4120.5,
        'best_effort': {'id': 'seg-1'},
      };

      final diagnosis = Diagnosis.fromJson(Map<String, dynamic>.from(json));

      expect(diagnosis.feasible, isFalse);
      expect(diagnosis.relaxations, hasLength(1));
      expect(diagnosis.relaxations.first.metric, 'climb_m');
      _expectSameJson(diagnosis.toJson(), json, 'diagnosis');
    });
  });

  group('the reader refuses what it cannot faithfully carry', () {
    test('an unknown field fails loudly rather than being dropped', () {
      // This is the property the whole file exists to protect: `done()` turns
      // "core grew a field the client does not know" into a clear error at the
      // boundary, instead of a value silently lost on the next write.
      final json = _load('boulder_trip.json')
        ..['a_field_from_a_newer_core'] = 'surprise';

      expect(() => Trip.fromJson(json), throwsA(isA<FormatException>()));
    });

    test('the error names the field and the shape it was on', () {
      try {
        Trip.fromJson(_load('boulder_trip.json')..['unread_field'] = 1);
        fail('expected a FormatException');
      } on FormatException catch (e) {
        expect(e.message, contains('unread_field'));
        expect(e.message, contains('trip'));
      }
    });

    test('an explicit null is refused — absent means unset', () {
      // The schema forbids null, so a null is a producer bug worth surfacing
      // rather than a value to coerce.
      expect(() => Trip.fromJson(_load('boulder_trip.json')..['title'] = null),
          throwsA(isA<FormatException>()));
    });

    test('a nested unknown field is caught at its own level', () {
      final json = _load('boulder_trip.json');
      (json['days'] as List).first['unexpected'] = true;

      expect(() => Trip.fromJson(json), throwsA(isA<FormatException>()));
    });
  });
}
