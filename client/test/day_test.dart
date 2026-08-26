// Story C2 (issue #38), FR18 — `Day.copyWith`'s clear flags, mirroring
// `Transition.copyWith`'s `clearNode` (FR12/B3): a bare `null` for `title`,
// `note`, or `location` means "leave it as it was," so an Author actually
// removing a rest day's itinerary note or its point needs an explicit flag
// rather than an accidental no-op.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  group('Day.copyWith clear flags', () {
    test('a bare null for title/note/location leaves the existing value alone', () {
      final day = Day(
        id: 'd1',
        index: 1,
        kind: 'rest',
        title: 'Hot springs day',
        note: 'Soak, then the main street shops.',
        location: const [-105.29, 40.0],
      );
      final same = day.copyWith();
      expect(same.title, 'Hot springs day');
      expect(same.note, 'Soak, then the main street shops.');
      expect(same.location, const [-105.29, 40.0]);
    });

    test('clearTitle removes the title without touching note or location', () {
      final day = Day(
        id: 'd1',
        index: 1,
        kind: 'rest',
        title: 'Hot springs day',
        note: 'Soak, then the main street shops.',
        location: const [-105.29, 40.0],
      );
      final cleared = day.copyWith(clearTitle: true);
      expect(cleared.title, isNull);
      expect(cleared.note, 'Soak, then the main street shops.');
      expect(cleared.location, const [-105.29, 40.0]);
    });

    test('clearNote removes the note only', () {
      final day = Day(id: 'd1', index: 1, kind: 'rest', note: 'Some detail');
      expect(day.copyWith(clearNote: true).note, isNull);
    });

    test('clearLocation removes the location only', () {
      final day = Day(id: 'd1', index: 1, kind: 'rest', location: const [1.0, 2.0]);
      expect(day.copyWith(clearLocation: true).location, isNull);
    });

    test('setting a new value while another field clears leaves the new value in place', () {
      final day = Day(id: 'd1', index: 1, kind: 'rest', title: 'Old title', note: 'Old note');
      final result = day.copyWith(title: 'New title', clearNote: true);
      expect(result.title, 'New title');
      expect(result.note, isNull);
    });
  });

  group('FR18 / C2 — a rest day composed of an area anchor (O3)', () {
    test('a rest day location can sit inside a trip-level area anchor, expressing what a point '
        'anchor could not', () {
      // The main-street/historic-district case C2's AC names directly:
      // FR108/O3's polygon geometry, not a point-plus-radius approximation.
      final mainStreet = Anchor(
        id: 'a1',
        coord: const [-105.30, 40.00],
        roles: [Role(id: 'r1', kind: RoleKind.narrative)],
        title: 'Historic Main Street',
        area: Area(rings: [
          [
            const [-105.31, 39.99],
            const [-105.29, 39.99],
            const [-105.29, 40.01],
            const [-105.31, 40.01],
            const [-105.31, 39.99],
          ],
        ]),
      );
      final restDay = Day(
        id: 'd2',
        index: 2,
        kind: 'rest',
        location: const [-105.30, 40.00],
        title: 'Wander the historic district',
      );

      expect(restDay.isRest, isTrue);
      expect(restDay.segments, isEmpty);
      expect(mainStreet.containsPoint(restDay.location!), isTrue);

      final trip = Trip(
        id: 't1',
        title: 'Test trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: [restDay],
        anchors: [mainStreet],
      );
      // Round-trips with no field loss — the area anchor and the rest day's
      // own location both survive a wire round trip untouched.
      final decoded = Trip.fromJson(trip.toJson());
      expect(decoded.anchors.single.area, isNotNull);
      expect(decoded.days.single.isRest, isTrue);
      expect(decoded.days.single.location, const [-105.30, 40.00]);
    });
  });
}
