// FR109, FR16b, FR24 / O4 — the client station-activity registry, the mirror
// of `core/plotlines_core/multimodal/station_activities.py`. There is no
// schema enum to pin against (activity_type is a plain string on purpose —
// see `station_activity_type.dart`), so this pins the registry's internal
// consistency and the `$defs/station_activity` shape the payload carries.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/station_activity_type.dart';

void main() {
  test('kStationActivityTypeKeys matches the registry, in order', () {
    expect(kStationActivityTypeKeys, kStationActivityTypes.keys.toList());
  });

  test('FR109 named three are present, plus the other PRD station cases', () {
    for (final k in ['climbing', 'canyoneering', 'jumaring']) {
      expect(kStationActivityTypes.containsKey(k), isTrue, reason: k);
    }
    // The other station cases the PRD reaches for.
    for (final k in ['summit_scramble', 'hot_spring', 'sauna', 'swimming']) {
      expect(kStationActivityTypes.containsKey(k), isTrue, reason: k);
    }
  });

  test('every activity has a non-empty label and a non-negative default duration', () {
    for (final a in kStationActivityTypes.values) {
      expect(a.label, isNotEmpty, reason: a.key);
      final d = a.defaultDurationS;
      if (d != null) {
        expect(d, greaterThanOrEqualTo(0), reason: a.key);
      }
    }
  });

  test('a station activity is never also a travel mode or a discipline key', () {
    const travelModes = ['cycling', 'hiking', 'paddling', 'cross_country_skiing',
      'driving', 'transit'];
    for (final k in kStationActivityTypeKeys) {
      expect(travelModes, isNot(contains(k)), reason: k);
    }
  });

  test('label and default duration fall through for an unknown activity (FR144)', () {
    expect(stationActivityLabel('via_ferrata'), 'via_ferrata');
    expect(defaultStationActivityDurationS('via_ferrata'), isNull);
    expect(stationActivityLabel('climbing'), 'Climbing');
    expect(defaultStationActivityDurationS('climbing'), 3 * 3600);
  });

  test(r'the schema carries $defs/station_activity and gates it to a station role', () {
    final schema = jsonDecode(
      File('../docs/schemas/trip_payload.schema.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final defs = schema[r'$defs'] as Map<String, dynamic>;

    final sa = defs['station_activity'] as Map<String, dynamic>;
    expect(sa['required'], contains('activity_type'));
    expect((sa['properties'] as Map).keys,
        containsAll(['activity_type', 'duration_s', 'required_gear', 'difficulty']));
    expect(sa['additionalProperties'], isFalse);
    // activity_type is a string, NOT an enum.
    expect((sa['properties']['activity_type'] as Map)['type'], 'string');
    expect((sa['properties']['activity_type'] as Map).containsKey('enum'), isFalse);

    final role = defs['role'] as Map<String, dynamic>;
    expect((role['properties']['activity'] as Map)[r'$ref'], r'#/$defs/station_activity');
    // FR109 — activity present ⇒ kind == station.
    final gate = (role['allOf'] as List).cast<Map<String, dynamic>>().firstWhere(
          (c) => ((c['if'] as Map?)?['required'] as List?)?.contains('activity') ?? false,
        );
    expect(((gate['then'] as Map)['properties'] as Map)['kind'], {'const': 'station'});
  });
}
