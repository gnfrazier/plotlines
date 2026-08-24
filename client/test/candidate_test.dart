// FR98/FR99 (Story N3) — Candidate wire parsing off `/candidates/score` and
// `/candidates`'s response shape.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/candidate.dart';

void main() {
  group('Candidate.fromJson', () {
    test('parses a fully-populated candidate', () {
      final candidate = Candidate.fromJson({
        'id': 'w123',
        'coord': [-105.27, 40.02],
        'layer': 'historic',
        'salience': 0.85,
        'role_affinity': 'narrative',
        'title': 'Old Fort',
        'tags': {'historic': 'fort', 'name': 'Old Fort'},
      });
      expect(candidate.id, 'w123');
      expect(candidate.coord, [-105.27, 40.02]);
      expect(candidate.layer, 'historic');
      expect(candidate.salience, 0.85);
      expect(candidate.roleAffinity, RoleAffinity.narrative);
      expect(candidate.title, 'Old Fort');
      expect(candidate.tags['historic'], 'fort');
    });

    test('title and tags are optional', () {
      final candidate = Candidate.fromJson({
        'id': 'n1',
        'coord': [0.0, 0.0],
        'layer': 'natural',
        'salience': 0.5,
        'role_affinity': 'provision',
      });
      expect(candidate.title, isNull);
      expect(candidate.tags, isEmpty);
    });

    test('an integer salience from JSON (e.g. 1) still parses as a double', () {
      final candidate = Candidate.fromJson({
        'id': 'n1',
        'coord': [0, 0],
        'layer': 'natural',
        'salience': 1,
        'role_affinity': 'station',
      });
      expect(candidate.salience, 1.0);
    });

    test('an unknown role_affinity throws rather than silently defaulting', () {
      expect(
        () => Candidate.fromJson({
          'id': 'n1',
          'coord': [0, 0],
          'layer': 'natural',
          'salience': 0.5,
          'role_affinity': 'sidekick',
        }),
        throwsFormatException,
      );
    });
  });
}
