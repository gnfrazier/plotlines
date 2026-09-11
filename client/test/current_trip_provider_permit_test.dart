// FR26 / C10 (issue #46) — the permit mutators this story adds: `addPermit`
// / `updatePermit` / `removePermit`, trip-scoped like `promoteAnchor`. Also
// covers `updateRole`'s FR25 / C9 `provision` wiring, mirroring
// `current_trip_provider_content_test.dart`'s `activity` coverage.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

void main() {
  Trip openTrip(ProviderContainer container) {
    final day = Day(id: 'day-1', index: 1, segments: [Segment(id: 'seg-1', mode: 'cycling', shape: 'loop')]);
    final anchor = Anchor(
      id: 'anchor-1',
      coord: const [-105.27, 40.02],
      roles: [Role(id: 'role-1', kind: RoleKind.provision)],
    );
    container.read(currentTripProvider.notifier).open(
          Trip(
            id: 't1', title: 'Test trip',
            createdAt: '2026-01-01T00:00:00Z', updatedAt: '2026-01-01T00:00:00Z',
            days: [day], anchors: [anchor],
          ),
        );
    return container.read(currentTripProvider);
  }

  group('addPermit / updatePermit / removePermit', () {
    test('addPermit appends a trip-scoped permit', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTrip(container);

      container.read(currentTripProvider.notifier).addPermit(
            Permit(id: 'p1', title: 'Backcountry permit'),
          );

      expect(container.read(currentTripProvider).permits.single.title, 'Backcountry permit');
    });

    test('updatePermit replaces the whole permit by id', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTrip(container);
      container.read(currentTripProvider.notifier).addPermit(
            Permit(id: 'p1', title: 'Backcountry permit', status: 'required'),
          );

      container.read(currentTripProvider.notifier).updatePermit(
            Permit(id: 'p1', title: 'Backcountry permit', status: 'confirmed',
                confirmationNumber: 'ABC-123'),
          );

      final permit = container.read(currentTripProvider).permits.single;
      expect(permit.status, 'confirmed');
      expect(permit.confirmationNumber, 'ABC-123');
    });

    test('removePermit drops just that permit', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTrip(container);
      final notifier = container.read(currentTripProvider.notifier);
      notifier.addPermit(Permit(id: 'a', title: 'A'));
      notifier.addPermit(Permit(id: 'b', title: 'B'));

      notifier.removePermit('a');

      expect(container.read(currentTripProvider).permits.map((p) => p.id), ['b']);
    });
  });

  group('updateRole — provision (FR25 / C9)', () {
    test('sets provision detail on the matching role only', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTrip(container);

      container.read(currentTripProvider.notifier).updateRole(
            'anchor-1', 'role-1',
            provision: ProvisionDetail(water: WaterSource(potable: true)),
          );

      final role = container.read(currentTripProvider).anchors.single.roles.single;
      expect(role.provision!.water!.potable, isTrue);
      expect(role.kind, RoleKind.provision);
    });

    test('clearProvision removes a previously-set detail', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTrip(container);
      container.read(currentTripProvider.notifier).updateRole(
            'anchor-1', 'role-1',
            provision: ProvisionDetail(water: WaterSource(potable: true)),
          );

      container.read(currentTripProvider.notifier).updateRole(
            'anchor-1', 'role-1', clearProvision: true,
          );

      expect(container.read(currentTripProvider).anchors.single.roles.single.provision, isNull);
    });
  });
}
