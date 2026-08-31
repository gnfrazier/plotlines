// FR27, FR115 (Story C11) — Hazard wire parsing: severity, safety note and
// gear callouts round-trip, a hazard pins to an anchor as well as a node or a
// point, and the two anchorings are mutually exclusive.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  group('Hazard', () {
    test('severity, safety note and gear round-trip through JSON', () {
      final json = {
        'id': 'h1',
        'severity': 'mandatory_reroute',
        'title': 'Washed-out bridge',
        'safety_note': 'Ford impassable above 2 m gauge. Use FS-19 detour.',
        'required_gear': ['helmet', 'throw bag'],
        'distance_along_m': 4321.0,
      };
      final h = Hazard.fromJson(Map<String, dynamic>.from(json));
      expect(h.severity, 'mandatory_reroute');
      expect(h.requiredGear, ['helmet', 'throw bag']);
      expect(h.toJson(), json);
    });

    test('pins to a promoted anchor', () {
      final h = Hazard.fromJson({'id': 'h2', 'severity': 'high', 'anchor_id': 'anchor-x'});
      expect(h.anchorId, 'anchor-x');
      expect(h.nodeId, isNull);
      expect(h.toJson()['anchor_id'], 'anchor-x');
    });

    test('node_id and anchor_id are mutually exclusive', () {
      expect(
        () => Hazard(id: 'h3', severity: 'high', nodeId: 'n1', anchorId: 'a1'),
        throwsA(isA<AssertionError>()),
      );
    });

    test('carries no reveal field — always visible per FR115', () {
      final h = Hazard(id: 'h4', severity: 'high');
      expect(h.toJson().containsKey('reveal'), isFalse);
    });
  });
}
