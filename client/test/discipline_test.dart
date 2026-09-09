// FR10 / FR130 [#315] — the client discipline registry, the second axis under
// a travel-mode category. Pins it against the schema's `$defs/discipline`
// enum, the core key list, and the M14 term catalog.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/discipline.dart';
import 'package:plotlines_client/domain/message_catalog.dart';
import 'package:plotlines_client/domain/travel_mode.dart';

void main() {
  test('kDisciplineKeys matches the registry, in order', () {
    expect(kDisciplineKeys, kDisciplines.keys.toList());
  });

  test('every discipline names a real category and a tier', () {
    for (final d in kDisciplines.values) {
      expect(kTravelCategories, contains(d.category), reason: d.key);
      expect([kDisciplineFirstClass, kDisciplineExtended], contains(d.tier),
          reason: d.key);
      expect(d.label, isNotEmpty, reason: d.key);
      expect(d.label, isNot(d.key), reason: d.key);
    }
  });

  test('disciplinesForCategory covers exactly the MVP set per category', () {
    expect(disciplinesForCategory('cycling'), ['road', 'gravel', 'mountain']);
    expect(disciplinesForCategory('hiking'), ['hike', 'run', 'trail_run']);
    expect(disciplinesForCategory('paddling'),
        ['canoe', 'kayak', 'packraft', 'riverboard']);
    expect(disciplinesForCategory('cross_country_skiing'),
        ['nordic', 'skimo', 'backcountry', 'resort']);
    expect(disciplinesForCategory('driving'), ['street', 'high_clearance']);
  });

  test('difficulty grading flag follows the owner\'s #315 table', () {
    // Land categories yes, water/snow no (data would come from a plugin).
    for (final k in ['road', 'gravel', 'mountain', 'hike', 'run', 'trail_run']) {
      expect(kDisciplines[k]!.gradesDifficulty, isTrue, reason: k);
    }
    for (final k in [
      'canoe', 'kayak', 'packraft', 'riverboard',
      'nordic', 'skimo', 'backcountry', 'resort',
      'street', 'high_clearance',
    ]) {
      expect(kDisciplines[k]!.gradesDifficulty, isFalse, reason: k);
    }
  });

  test('categoryOfDiscipline / disciplineLabel fall through for an unknown key', () {
    expect(categoryOfDiscipline('wingfoiling'), isNull);
    expect(disciplineLabel('wingfoiling'), 'wingfoiling');
  });

  test('a discipline is never also a mode or a station activity', () {
    for (final k in kDisciplineKeys) {
      expect(kTravelModes, isNot(contains(k)), reason: k);
      expect(['climbing', 'canyoneering', 'jumaring'], isNot(contains(k)), reason: k);
    }
  });

  test('FR145/M14: every discipline has a term whose en string is its label', () {
    const resolver = MessageResolver();
    for (final k in kDisciplineKeys) {
      final id = resolver.disciplineTerm(k);
      expect(id, isNotNull, reason: 'no message term for discipline "$k"');
      expect(resolver.resolve(id!), disciplineLabel(k), reason: k);
    }
    expect(resolver.disciplineTerm('wingfoiling'), isNull);
  });

  test('the schema \$defs/discipline enum is exactly kDisciplineKeys', () {
    final schema = jsonDecode(
      File('../docs/schemas/trip_payload.schema.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final defs = schema[r'$defs'] as Map<String, dynamic>;
    final enumValues = (defs['discipline'] as Map<String, dynamic>)['enum'] as List;
    expect(enumValues.cast<String>(), kDisciplineKeys);
  });
}
