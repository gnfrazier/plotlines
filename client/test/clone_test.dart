// FR74 / FR74b (Stories G2, G2b) and ARCH §11.8 — clone semantics as an
// enumerated copy. §4.33's cloned-trip check is run here **once per scope**
// (the `for (final scope in CloneScope.values)` group), per punchlist §4.35.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/anchor.dart';
import 'package:plotlines_client/domain/clone.dart';
import 'package:plotlines_client/domain/day.dart';
import 'package:plotlines_client/domain/roster.dart';
import 'package:plotlines_client/domain/route_metrics.dart';
import 'package:plotlines_client/domain/trip.dart';

Trip _sourceTrip() => Trip(
      id: 'src-1',
      title: 'Blue Ridge Traverse',
      createdAt: '2025-01-01T00:00:00.000Z',
      updatedAt: '2025-02-01T00:00:00.000Z',
      duration: TripDuration(dayCount: 3),
      metrics: RollUp(total: RouteMetrics(distanceM: 42000, climbM: 900)),
      days: [Day(id: 'd1', index: 0, title: 'Day 1'), Day(id: 'd2', index: 1)],
      anchors: [
        Anchor(
          id: 'a1',
          coord: [-82.55, 35.6],
          title: 'Hot Spring',
          roles: [Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival)],
        ),
      ],
    );

TripRoster _sourceRoster() => const TripRoster(
      entries: [
        RosterEntry(
          characterId: 'ann',
          name: 'Ann',
          groupLabel: 'Fast',
          dayGroupOverrides: {'d1': 'Slow'},
        ),
        RosterEntry(characterId: 'bo', name: 'Bo', groupLabel: 'Slow'),
      ],
      gear: [GearAssignment(id: 'g1', label: 'Tent', assigneeIds: {'ann', 'bo'})],
      meals: [MealResponsibility(id: 'm1', label: 'Dinner', cookIds: {'ann'})],
      authorNotes: [
        AuthorNote(subjectCharacterId: 'ann', body: 'Strong scrambler.', updatedAt: '2024-06-01T00:00:00.000Z'),
      ],
    );

CloneOutcome _clone(CloneScope scope, {CloneParts parts = const CloneParts()}) => cloneTrip(
      source: _sourceTrip(),
      sourceRoster: _sourceRoster(),
      sourceDeclaredModes: {'hiking', 'cycling'},
      scope: scope,
      parts: parts,
      newId: 'clone-1',
      nowIso: '2026-08-28T12:00:00.000Z',
    );

void main() {
  group('describeClone — states carried / not-carried before the clone runs', () {
    test('whole trip carries the authored trip and the roster', () {
      final m = describeClone(CloneScope.wholeTrip);
      expect(m.carried, contains(startsWith('The authored trip')));
      expect(m.carried, contains('Roster membership'));
      expect(m.carried, contains('Group and sub-group assignments'));
      expect(m.runsTripInitiation, isFalse);
    });

    test('roster only carries the roster, not the authored trip, and runs trip init', () {
      final m = describeClone(CloneScope.rosterOnly);
      expect(m.carried, contains('Roster membership'));
      expect(m.carried, isNot(contains(startsWith('The authored trip'))));
      expect(m.notCarried, contains(startsWith('Days, passages, anchors, and content')));
      expect(m.runsTripInitiation, isTrue);
    });

    test('authored trip only carries the trip with an empty roster', () {
      final m = describeClone(CloneScope.authoredTripOnly);
      expect(m.carried, contains(startsWith('The authored trip')));
      expect(m.carried, isNot(contains('Roster membership')));
      expect(m.notCarried, contains(startsWith('The roster')));
      expect(m.runsTripInitiation, isFalse);
    });

    test('per-part reflects the chosen booleans', () {
      final rosterOnly = describeClone(CloneScope.perPart, parts: const CloneParts(roster: true));
      expect(rosterOnly.carried, contains('Roster membership'));
      expect(rosterOnly.runsTripInitiation, isTrue);

      final both = describeClone(CloneScope.perPart,
          parts: const CloneParts(roster: true, authoredTrip: true));
      expect(both.carried, contains(startsWith('The authored trip')));
      expect(both.runsTripInitiation, isFalse);
    });

    test('every scope names consent and Character-layer state as NOT carried', () {
      for (final scope in CloneScope.values) {
        final m = describeClone(scope, parts: const CloneParts(roster: true, authoredTrip: true));
        expect(m.notCarried, contains(startsWith('Profile grants')), reason: '$scope');
        expect(m.notCarried, contains('Arrival-visibility permission'), reason: '$scope');
        expect(m.notCarried, contains('Reveals, arrivals, and in-story choices'), reason: '$scope');
        expect(m.carriesConsent, isFalse, reason: '$scope');
        expect(m.carried, isNot(contains(contains('grant'))), reason: '$scope');
      }
    });
  });

  group('§4.33 cloned-trip check — once per scope', () {
    for (final scope in CloneScope.values) {
      test('$scope: fresh id/timestamps, and no consent or Character-layer state', () {
        final parts = scope == CloneScope.perPart
            ? const CloneParts(roster: true, authoredTrip: true)
            : const CloneParts();
        final out = _clone(scope, parts: parts);

        // A clone is a new trip, not a mutation of the source.
        expect(out.trip.id, 'clone-1');
        expect(out.trip.id, isNot('src-1'));
        expect(out.trip.createdAt, '2026-08-28T12:00:00.000Z');
        expect(out.trip.updatedAt, '2026-08-28T12:00:00.000Z');
        expect(out.trip.title, isNot('Blue Ridge Traverse'));

        // TripRoster carries no grant/permission/reveal/arrival/choice field —
        // it has no such field, and the payload has none either. The exclusion
        // is structural; this asserts the model stayed that way.
        final rosterJson = out.roster.toJson().toString();
        expect(rosterJson, isNot(contains('grant')));
        expect(rosterJson, isNot(contains('reveal')));
        expect(rosterJson, isNot(contains('arrival')));
        final payloadJson = out.trip.toJson().toString();
        expect(payloadJson, isNot(contains('profile_grant')));
      });
    }
  });

  group('whole trip', () {
    test('copies the payload in full — days, anchors, roles, duration, metrics', () {
      final out = _clone(CloneScope.wholeTrip);
      expect(out.trip.days.map((d) => d.id), ['d1', 'd2']);
      expect(out.trip.anchors.single.roles.single.reveal, RevealPolicy.onArrival);
      expect(out.trip.duration!.dayCount, 3);
      expect(out.trip.metrics!.total!.distanceM, 42000);
      expect(out.declaredModes, {'hiking', 'cycling'});
      expect(out.runsTripInitiation, isFalse);
    });

    test('carries roster membership, groups, gear, meals, and Author notes', () {
      final out = _clone(CloneScope.wholeTrip);
      expect(out.roster.entries.map((e) => e.characterId), ['ann', 'bo']);
      expect(out.roster.entries.first.groupLabel, 'Fast');
      expect(out.roster.entries.first.dayGroupOverrides, {'d1': 'Slow'});
      expect(out.roster.gear.single.assigneeIds, {'ann', 'bo'});
      expect(out.roster.meals.single.cookIds, {'ann'});
      expect(out.roster.authorNotes.single.body, 'Strong scrambler.');
      // D6 — Author-note updated_at is preserved verbatim, never bumped.
      expect(out.roster.authorNotes.single.updatedAt, '2024-06-01T00:00:00.000Z');
    });

    test('does not mutate the source trip or roster', () {
      final src = _sourceTrip();
      final srcRoster = _sourceRoster();
      cloneTrip(
        source: src,
        sourceRoster: srcRoster,
        sourceDeclaredModes: {'hiking'},
        scope: CloneScope.wholeTrip,
        newId: 'x',
        nowIso: 'now',
      );
      expect(src.id, 'src-1');
      expect(src.title, 'Blue Ridge Traverse');
      expect(srcRoster.entries, hasLength(2));
    });
  });

  group('roster only', () {
    test('produces a trip with no days and no anchors', () {
      final out = _clone(CloneScope.rosterOnly);
      expect(out.trip.days, isEmpty);
      expect(out.trip.anchors, isEmpty);
      expect(out.trip.duration, isNull);
    });

    test('keeps membership and group assignments, drops per-day/per-passage overrides', () {
      final out = _clone(CloneScope.rosterOnly);
      expect(out.roster.entries.map((e) => e.characterId), ['ann', 'bo']);
      expect(out.roster.entries.first.groupLabel, 'Fast');
      expect(out.roster.entries.first.dayGroupOverrides, isEmpty);
    });

    test('runs trip initiation and starts with no declared modes', () {
      final out = _clone(CloneScope.rosterOnly);
      expect(out.runsTripInitiation, isTrue);
      expect(out.declaredModes, isEmpty);
    });
  });

  group('authored trip only', () {
    test('full structure with an empty roster', () {
      final out = _clone(CloneScope.authoredTripOnly);
      expect(out.trip.days.map((d) => d.id), ['d1', 'd2']);
      expect(out.trip.anchors, hasLength(1));
      expect(out.roster.isEmpty, isTrue);
      expect(out.declaredModes, {'hiking', 'cycling'});
    });

    test('everything assigned to (now absent) people is dropped, not dangling', () {
      final out = _clone(CloneScope.authoredTripOnly);
      expect(out.roster.entries, isEmpty);
      expect(out.roster.gear, isEmpty);
      expect(out.roster.meals, isEmpty);
      expect(out.roster.authorNotes, isEmpty);
    });
  });

  group('per-part', () {
    test('roster + no authored trip behaves like roster-only', () {
      final out = _clone(CloneScope.perPart, parts: const CloneParts(roster: true));
      expect(out.trip.days, isEmpty);
      expect(out.roster.entries, hasLength(2));
      expect(out.runsTripInitiation, isTrue);
    });

    test('authored trip + no roster behaves like authored-trip-only', () {
      final out = _clone(CloneScope.perPart, parts: const CloneParts(authoredTrip: true));
      expect(out.trip.days, hasLength(2));
      expect(out.roster.isEmpty, isTrue);
      expect(out.runsTripInitiation, isFalse);
    });
  });

  test('Author notes are present exactly when the roster is (no rule applied)', () {
    for (final scope in CloneScope.values) {
      for (final parts in const [
        CloneParts(),
        CloneParts(roster: true),
        CloneParts(authoredTrip: true),
        CloneParts(roster: true, authoredTrip: true),
      ]) {
        final out = _clone(scope, parts: parts);
        final rosterCarried = out.roster.entries.isNotEmpty;
        expect(out.roster.authorNotes.isNotEmpty, rosterCarried,
            reason: 'scope=$scope parts=(${parts.roster},${parts.authoredTrip})');
      }
    }
  });
}
