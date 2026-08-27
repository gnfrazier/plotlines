// E1 (FR37) — the content mutators this story adds: `updateRole` (a role's
// note/media, post-promotion — O1's AC named "set here or later," and this
// is "later"), `updateSegmentNote`/`updateSegmentMedia` (a passage's own
// content), and `updateDayMedia` (a day's own media; `Day.note` already had
// `setDayNote`). Each touches only its own field, the same "wholesale-replace
// one field" idiom `current_trip_provider_arc_stage_test.dart` documents.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

void main() {
  Trip openTrip(ProviderContainer container) {
    final segment = Segment(id: 'seg-1', mode: 'cycling', shape: 'loop');
    final day = Day(id: 'day-1', index: 1, segments: [segment]);
    final anchor = Anchor(
      id: 'anchor-1',
      coord: const [-105.27, 40.02],
      roles: [
        Role(id: 'role-1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival),
      ],
    );
    container.read(currentTripProvider.notifier).open(
          Trip(
            id: 't1',
            title: 'Test trip',
            createdAt: '2026-01-01T00:00:00Z',
            updatedAt: '2026-01-01T00:00:00Z',
            days: [day],
            anchors: [anchor],
          ),
        );
    return container.read(currentTripProvider);
  }

  group('updateRole', () {
    test('sets note and media on the matching role only, leaving reveal/kind untouched', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTrip(container);

      container.read(currentTripProvider.notifier).updateRole(
            'anchor-1',
            'role-1',
            note: 'Bob arrives by train Tuesday morning.',
            media: [MediaRef(id: 'm1', kind: 'image', path: 'trailhead.jpg')],
          );

      final role = container.read(currentTripProvider).anchors.single.roles.single;
      expect(role.note, 'Bob arrives by train Tuesday morning.');
      expect(role.media.single.path, 'trailhead.jpg');
      expect(role.kind, RoleKind.narrative);
      expect(role.reveal, RevealPolicy.onArrival);
    });

    test('clearNote removes a previously-set note without touching media', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTrip(container);
      container.read(currentTripProvider.notifier).updateRole(
            'anchor-1',
            'role-1',
            note: 'draft note',
            media: [MediaRef(id: 'm1', kind: 'image', path: 'a.jpg')],
          );

      container.read(currentTripProvider.notifier).updateRole('anchor-1', 'role-1', clearNote: true);

      final role = container.read(currentTripProvider).anchors.single.roles.single;
      expect(role.note, isNull);
      expect(role.media.single.path, 'a.jpg');
    });

    test('leaves a non-matching anchor/role untouched', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTrip(container);

      container
          .read(currentTripProvider.notifier)
          .updateRole('anchor-1', 'role-1', note: 'set once');
      container
          .read(currentTripProvider.notifier)
          .updateRole('does-not-exist', 'role-1', note: 'should not apply');

      expect(container.read(currentTripProvider).anchors.single.roles.single.note, 'set once');
    });
  });

  group('updateSegmentNote / updateSegmentMedia', () {
    test('sets a passage note and media distinct from the day\'s own', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTrip(container);

      container.read(currentTripProvider.notifier).updateSegmentNote('day-1', 'seg-1', 'Passage note.');
      container.read(currentTripProvider.notifier).updateSegmentMedia(
            'day-1',
            'seg-1',
            [MediaRef(id: 'm1', kind: 'image', path: 'passage.jpg')],
          );
      container.read(currentTripProvider.notifier).setDayNote('day-1', 'Day note.');

      final trip = container.read(currentTripProvider);
      final segment = trip.days.single.segments.single;
      expect(segment.note, 'Passage note.');
      expect(segment.media.single.path, 'passage.jpg');
      expect(trip.days.single.note, 'Day note.');
    });

    test('an empty string clears the passage note', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTrip(container);
      container.read(currentTripProvider.notifier).updateSegmentNote('day-1', 'seg-1', 'set');

      container.read(currentTripProvider.notifier).updateSegmentNote('day-1', 'seg-1', '');

      expect(container.read(currentTripProvider).days.single.segments.single.note, isNull);
    });
  });

  group('updateDayMedia', () {
    test('sets the day\'s own media, distinct from any segment\'s', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      openTrip(container);

      container.read(currentTripProvider.notifier).updateDayMedia(
            'day-1',
            [MediaRef(id: 'm1', kind: 'image', path: 'camp.jpg')],
          );

      final day = container.read(currentTripProvider).days.single;
      expect(day.media.single.path, 'camp.jpg');
      expect(day.segments.single.media, isEmpty);
    });
  });
}
