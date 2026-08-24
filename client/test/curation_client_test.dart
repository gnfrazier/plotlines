// FR97/FR98 (Story N3) — the pure, network-free parts of CurationClient:
// request-shape construction and error-message decoding. Mirrors the scope
// `RoutingException`'s own tests would cover — no live HTTP is exercised
// here (`CurationClient` uses the same base-URL-only transport pattern as
// `RoutingClient`, which has no network-mocked test in this repo either).
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/curation_client.dart';

void main() {
  group('RawCandidateFeature.toJson', () {
    test('includes area_m2 only when set', () {
      final withArea = RawCandidateFeature(
        id: '1',
        coord: [-105.27, 40.02],
        tags: const {'leisure': 'park', 'name': 'Test Park'},
        areaM2: 25000.0,
      );
      expect(withArea.toJson(), {
        'id': '1',
        'coord': [-105.27, 40.02],
        'tags': {'leisure': 'park', 'name': 'Test Park'},
        'area_m2': 25000.0,
      });

      final withoutArea = RawCandidateFeature(id: '2', coord: [0, 0]);
      expect(withoutArea.toJson().containsKey('area_m2'), isFalse);
    });
  });

  group('LayerCatalog.fromJson', () {
    test('parses layers and default_live as sets/lists', () {
      final catalog = LayerCatalog.fromJson({
        'layers': ['sight', 'amenity', 'natural', 'historic', 'leisure', 'man_made'],
        'default_live': ['sight', 'historic'],
        'ruleset_version': '1.0.0',
      });
      expect(catalog.layers, hasLength(6));
      expect(catalog.defaultLive, {'sight', 'historic'});
      expect(catalog.rulesetVersion, '1.0.0');
    });
  });

  group('CurationException.message', () {
    test('decodes a FastAPI-style {"detail": "..."} body', () {
      final exc = CurationException(422, '{"detail": "no data for area"}');
      expect(exc.message, 'no data for area');
    });

    test('falls back to the raw body for non-JSON responses', () {
      final exc = CurationException(500, 'internal server error');
      expect(exc.message, 'internal server error');
    });

    test('reports a placeholder for an empty body', () {
      final exc = CurationException(503, '');
      expect(exc.message, 'Request failed (503)');
    });
  });
}
