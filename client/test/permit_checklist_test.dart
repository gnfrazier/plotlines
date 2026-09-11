// FR26 (Story C10) — the client half of the pre-trip permit checklist.
// `plotlines_core.trips.permits` is the authority; this pins that
// `PermitChecklist.fromTrip` scopes, orders, and tallies the same way.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/domain.dart';

Trip _trip(List<Permit> permits, {List<Anchor> anchors = const []}) => Trip(
      id: 'trip-1',
      title: 'Permit trip',
      createdAt: '2026-09-11T00:00:00Z',
      updatedAt: '2026-09-11T00:00:00Z',
      permits: permits,
      anchors: anchors,
    );

void main() {
  group('PermitChecklist.fromTrip — the client mirror of trips.permits', () {
    test('reads trip permits in order', () {
      final checklist = PermitChecklist.fromTrip(_trip([
        Permit(id: 'p1', title: 'First', status: 'confirmed'),
        Permit(id: 'p2', title: 'Second', status: 'confirmed'),
      ]));
      expect(checklist.permits.map((lp) => lp.permit.title), ['First', 'Second']);
    });

    test('scopes trip, passage, and anchor', () {
      final checklist = PermitChecklist.fromTrip(_trip([
        Permit(id: 'p1', title: 'Annual pass', status: 'confirmed'),
        Permit(id: 'p2', title: 'Put-in permit', status: 'required', segmentId: 'seg-1'),
        Permit(id: 'p3', title: 'Trailhead permit', status: 'required', anchorId: 'anchor-1'),
      ]));
      final byTitle = {for (final lp in checklist.permits) lp.permit.title: lp.scope};
      expect(byTitle['Annual pass'], 'trip');
      expect(byTitle['Put-in permit'], 'passage');
      expect(byTitle['Trailhead permit'], 'anchor');
    });

    test('resolves anchor title', () {
      final checklist = PermitChecklist.fromTrip(_trip(
        [Permit(id: 'p1', title: 'Backcountry permit', anchorId: 'anchor-1')],
        anchors: [
          Anchor(id: 'anchor-1', coord: const [0.0, 0.0], title: 'Ranger Station',
              roles: [Role(id: 'r1', kind: RoleKind.provision)]),
        ],
      ));
      expect(checklist.permits.single.anchorTitle, 'Ranger Station');
    });

    test('orders worst-first: denied, then required, then applied, then confirmed', () {
      final checklist = PermitChecklist.fromTrip(_trip([
        Permit(id: 'p1', title: 'Confirmed one', status: 'confirmed'),
        Permit(id: 'p2', title: 'Denied one', status: 'denied'),
        Permit(id: 'p3', title: 'Applied one', status: 'applied'),
        Permit(id: 'p4', title: 'Required one', status: 'required'),
      ]));
      expect(
        checklist.permits.map((lp) => lp.permit.status).toList(),
        ['denied', 'required', 'applied', 'confirmed'],
      );
    });

    test('tallies needsAttentionCount and isClear', () {
      final allConfirmed = PermitChecklist.fromTrip(_trip([
        Permit(id: 'p1', title: 'a', status: 'confirmed'),
        Permit(id: 'p2', title: 'b', status: 'confirmed'),
      ]));
      expect(allConfirmed.needsAttentionCount, 0);
      expect(allConfirmed.isClear, isTrue);

      final mixed = PermitChecklist.fromTrip(_trip([
        Permit(id: 'p1', title: 'a', status: 'confirmed'),
        Permit(id: 'p2', title: 'b', status: 'required'),
      ]));
      expect(mixed.needsAttentionCount, 1);
      expect(mixed.isClear, isFalse);
    });

    test('is clear on an empty trip', () {
      expect(PermitChecklist.fromTrip(_trip(const [])).isClear, isTrue);
    });
  });
}
