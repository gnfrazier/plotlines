// FR26 (Story C10) — Permit wire parsing: status, confirmation number, link
// and note round-trip, a permit pins to a promoted anchor as well as a
// passage, and the two anchorings are mutually exclusive.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  group('Permit', () {
    test('title, status, confirmation number, link and note round-trip through JSON', () {
      final json = {
        'id': 'p1',
        'title': 'Backcountry permit',
        'status': 'confirmed',
        'confirmation_number': 'RVR-2026-0091',
        'link': 'https://parks.example.gov/permits/RVR-2026-0091',
        'note': 'Print two copies.',
      };
      final p = Permit.fromJson(Map<String, dynamic>.from(json));
      expect(p.status, 'confirmed');
      expect(p.confirmationNumber, 'RVR-2026-0091');
      expect(p.toJson(), json);
    });

    test('defaults status to required when absent on read', () {
      final p = Permit.fromJson({'id': 'p2', 'title': 'Parking pass'});
      expect(p.status, 'required');
    });

    test('pins to a promoted anchor', () {
      final p = Permit.fromJson({'id': 'p3', 'title': 'Trailhead permit', 'anchor_id': 'anchor-x'});
      expect(p.anchorId, 'anchor-x');
      expect(p.segmentId, isNull);
      expect(p.toJson()['anchor_id'], 'anchor-x');
    });

    test('pins to a passage', () {
      final p = Permit(id: 'p4', title: 'Put-in permit', segmentId: 'seg-1');
      expect(p.toJson()['segment_id'], 'seg-1');
    });

    test('segment_id and anchor_id are mutually exclusive', () {
      expect(
        () => Permit(id: 'p5', title: 'x', segmentId: 's1', anchorId: 'a1'),
        throwsA(isA<AssertionError>()),
      );
    });

    test('needsAttention is everything short of confirmed', () {
      expect(Permit(id: 'p', title: 'x', status: 'required').needsAttention, isTrue);
      expect(Permit(id: 'p', title: 'x', status: 'applied').needsAttention, isTrue);
      expect(Permit(id: 'p', title: 'x', status: 'denied').needsAttention, isTrue);
      expect(Permit(id: 'p', title: 'x', status: 'confirmed').needsAttention, isFalse);
    });

    test('copyWith preserves fields by default and clears via the clear flags', () {
      final p = Permit(
        id: 'p6', title: 'x', confirmationNumber: 'ABC', link: 'https://x', note: 'n',
      );
      final unchanged = p.copyWith(status: 'confirmed');
      expect(unchanged.confirmationNumber, 'ABC');
      expect(unchanged.status, 'confirmed');
      final cleared = p.copyWith(
        clearConfirmationNumber: true, clearLink: true, clearNote: true,
      );
      expect(cleared.confirmationNumber, isNull);
      expect(cleared.link, isNull);
      expect(cleared.note, isNull);
    });
  });
}
