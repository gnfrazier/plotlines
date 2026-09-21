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

    // Issue #403 — the candidate's own geometry, when the source feature was
    // an area or a line, is the RFC 7946 object the payload speaks and is
    // read kind-tagged; `geometry: null` (a point) is what the sidecar sends.
    test('reads a Polygon geometry as a CandidatePolygon with its area', () {
      final candidate = Candidate.fromJson({
        'id': 'w9',
        'coord': [0.005, 0.003],
        'layer': 'leisure',
        'salience': 0.6,
        'role_affinity': 'station',
        'area_m2': 30000.0,
        'geometry': {
          'type': 'Polygon',
          'coordinates': [
            [
              [0.0, 0.0],
              [0.01, 0.0],
              [0.01, 0.01],
              [0.0, 0.0],
            ]
          ],
        },
      });
      expect(candidate.areaM2, 30000.0);
      final geometry = candidate.geometry;
      expect(geometry, isA<CandidatePolygon>());
      expect((geometry as CandidatePolygon).ring, [
        [0.0, 0.0],
        [0.01, 0.0],
        [0.01, 0.01],
        [0.0, 0.0],
      ]);
    });

    test('reads a LineString geometry as a CandidateLine', () {
      final candidate = Candidate.fromJson({
        'id': 'byway/1',
        'coord': [0.05, 0.02],
        'layer': 'byways',
        'salience': 0.7,
        'role_affinity': 'narrative',
        'area_m2': null,
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [0, 0],
            [0.05, 0.02],
            [0.1, 0],
          ],
        },
      });
      expect(candidate.areaM2, isNull);
      final geometry = candidate.geometry;
      expect(geometry, isA<CandidateLine>());
      expect((geometry as CandidateLine).coords, [
        [0.0, 0.0],
        [0.05, 0.02],
        [0.1, 0.0],
      ]);
    });

    test('a point candidate carries null geometry, absent or explicit', () {
      final explicit = Candidate.fromJson({
        'id': 'n1',
        'coord': [0.0, 0.0],
        'layer': 'natural',
        'salience': 0.5,
        'role_affinity': 'provision',
        'area_m2': null,
        'geometry': null,
      });
      expect(explicit.geometry, isNull);
      expect(explicit.areaM2, isNull);
    });

    test('an unknown geometry type throws rather than silently dropping the shape', () {
      expect(
        () => Candidate.fromJson({
          'id': 'n1',
          'coord': [0.0, 0.0],
          'layer': 'natural',
          'salience': 0.5,
          'role_affinity': 'provision',
          'geometry': {'type': 'MultiPolygon', 'coordinates': []},
        }),
        throwsFormatException,
      );
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

  group('CandidateExtraction.fromJson (#415)', () {
    test('carries layers_served and layers_unavailable alongside the candidates', () {
      final x = CandidateExtraction.fromJson({
        'candidates': [
          {
            'id': 'n1',
            'coord': [-105.2, 40.0],
            'layer': 'sight',
            'salience': 0.8,
            'role_affinity': 'narrative',
          },
        ],
        'layers_served': ['sight', 'natural'],
        'layers_unavailable': {'plugin_crags': 'failed:TimeoutError', 'historic': 'loading'},
      });
      expect(x.candidates.map((c) => c.id), ['n1']);
      expect(x.layersServed, ['sight', 'natural']);
      expect(x.layersUnavailable, {'plugin_crags': 'failed:TimeoutError', 'historic': 'loading'});
      expect(x.isPartial, isTrue);
      expect(x.isTotalFailure, isFalse);
    });

    test('a response with only candidates (older sidecar) is neither partial nor failed', () {
      final x = CandidateExtraction.fromJson({'candidates': []});
      expect(x.layersServed, isEmpty);
      expect(x.layersUnavailable, isEmpty);
      expect(x.isPartial, isFalse);
      expect(x.isTotalFailure, isFalse);
    });

    test('nothing served and something unavailable is the total case, not the partial one', () {
      final x = CandidateExtraction.fromJson({
        'candidates': [],
        'layers_served': [],
        'layers_unavailable': {'sight': 'failed:ConnectionError', 'natural': 'failed:ConnectionError'},
      });
      expect(x.isPartial, isFalse);
      expect(x.isTotalFailure, isTrue);
    });
  });
}
