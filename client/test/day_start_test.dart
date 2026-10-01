// Issue #563 — a day's start time (UTC + IANA zone), its conversion to and
// from the day's wall clock, the station holds that feed elapsed time, and
// the local dashboard mirror's ETA, which must match `build_dashboard`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';

Segment _leg(String id, String mode, double distanceM) =>
    Segment(id: id, mode: mode, shape: 'point_to_point', metrics: RouteMetrics(distanceM: distanceM));

Anchor _station(String id, {required String dayId, double? seconds}) => Anchor(
      id: id,
      title: id,
      coord: const [-105.3, 40.0],
      roles: [
        Role(
          id: 'r-$id',
          kind: RoleKind.station,
          reveal: RevealPolicy.alwaysVisible,
          activity: StationActivity(activityType: 'climbing', durationS: seconds),
          dayId: dayId,
        ),
      ],
    );

Trip _trip({List<Day>? days, List<Anchor> anchors = const []}) => Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: days ?? [Day(id: 'd1', index: 1, segments: [_leg('s1', 'cycling', 30000)])],
      anchors: anchors,
    );

void main() {
  group('start time conversion', () {
    test('a summer start on New York time is stored as UTC (EDT, -4)', () {
      expect(startAtFromLocal('2026-07-04', 7, 0, 'America/New_York'), '2026-07-04T11:00:00Z');
    });

    test('the same wall clock in winter is an hour later in UTC (EST, -5)', () {
      expect(startAtFromLocal('2026-01-10', 7, 0, 'America/New_York'), '2026-01-10T12:00:00Z');
    });

    test('a stored start reads back on the zone it was declared in', () {
      final local = wallClockIn('2026-07-04T11:00:00Z', 'America/Denver')!;
      expect((local.hour, local.minute), (5, 0));
      expect(local.timeZoneName, 'MDT');
    });

    test('an unknown zone or a malformed stamp reads as nothing, not a guess', () {
      expect(wallClockIn('2026-07-04T11:00:00Z', 'Mars/Olympus'), isNull);
      expect(wallClockIn('soon', 'America/Denver'), isNull);
    });

    test('a new start defaults to a zone another day of the trip already uses', () {
      final trip = _trip(days: [
        Day(id: 'd1', index: 1),
        Day(id: 'd2', index: 2, startAt: '2026-07-05T13:00:00Z', startTimezone: 'Europe/Paris'),
      ]);
      expect(defaultStartZone(trip), 'Europe/Paris');
      expect(isKnownTimeZone(defaultStartZone(_trip())), isTrue);
    });
  });

  group('Day JSON', () {
    test('start_at and start_timezone round-trip, and are absent when unset', () {
      final day = Day(id: 'd1', index: 1, startAt: '2026-07-04T11:00:00Z', startTimezone: 'America/New_York');
      final json = day.toJson();
      expect(json['start_at'], '2026-07-04T11:00:00Z');
      expect(json['start_timezone'], 'America/New_York');
      final read = Day.fromJson(json);
      expect((read.startAt, read.startTimezone), ('2026-07-04T11:00:00Z', 'America/New_York'));
      expect(Day(id: 'd2', index: 2).toJson().containsKey('start_at'), isFalse);
    });

    test('clearStart takes both halves off together', () {
      final day = Day(id: 'd1', index: 1, startAt: '2026-07-04T11:00:00Z', startTimezone: 'America/New_York');
      final cleared = day.copyWith(clearStart: true);
      expect((cleared.startAt, cleared.startTimezone), (null, null));
    });
  });

  group('station holds', () {
    test('sum the station durations attached to each day, ignoring unattached and untimed ones', () {
      final trip = _trip(anchors: [
        _station('a', dayId: 'd1', seconds: 3600),
        _station('b', dayId: 'd1', seconds: 1800),
        _station('c', dayId: 'd2', seconds: null),
      ]);
      expect(dayStationHoldS(trip), {'d1': 5400.0});
    });
  });

  group('TripDashboard.fromTrip', () {
    test('elapsed time includes the day\'s station holds', () {
      final board = TripDashboard.fromTrip(_trip(anchors: [_station('a', dayId: 'd1', seconds: 5400)]));
      final day = board.dayLine('d1')!;
      expect(day.metrics.total!.movingTimeS, 7200.0); // 30 km @ 15 km/h
      expect(day.metrics.total!.elapsedTimeS, 12600.0);
      expect(day.holdS, 5400.0);
      expect(board.tripHoldS, 5400.0);
      expect(board.tripTotal.total!.elapsedTimeS, 12600.0);
    });

    test('a day with a start time gets start + elapsed as its ETA, matching build_dashboard', () {
      // The core test's own case: 06:00Z + 13 800 s = 09:50Z
      // (`test_dashboard.py::test_day_eta_is_the_day_start_plus_its_elapsed_time`).
      final trip = _trip(
        days: [
          Day(id: 'd1', index: 1, startAt: '2026-08-28T06:00:00Z', startTimezone: 'America/Denver',
              segments: [_leg('s1', 'cycling', 35000)]), // 8400 s moving
          Day(id: 'd2', index: 2, segments: [_leg('s2', 'cycling', 30000)]),
        ],
        anchors: [_station('a', dayId: 'd1', seconds: 5400)],
      );
      final board = TripDashboard.fromTrip(trip);
      expect(board.dayLine('d1')!.metrics.total!.elapsedTimeS, 13800.0);
      expect(board.dayLine('d1')!.eta, '2026-08-28T09:50:00Z');
      expect(board.dayLine('d2')!.eta, isNull, reason: 'no start time, no ETA — never a guessed one');
    });
  });

  group('CurrentTripNotifier.setDayStart', () {
    test('sets both halves on that day, and clearing takes both off', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(currentTripProvider.notifier)..open(_trip());

      notifier.setDayStart('d1', startAt: '2026-07-04T11:00:00Z', timezone: 'America/New_York');
      var day = container.read(currentTripProvider).days.single;
      expect((day.startAt, day.startTimezone), ('2026-07-04T11:00:00Z', 'America/New_York'));

      notifier.setDayStart('d1');
      day = container.read(currentTripProvider).days.single;
      expect((day.startAt, day.startTimezone), (null, null));
    });
  });

  group('dashboardFor', () {
    test('uses the server dashboard only for the exact trip it was computed for', () {
      final trip = _trip();
      final server = TripDashboard(
          tripId: 't1', tripTitle: 'Test trip', paceSource: paceSystemDefault, tripTotal: RollUp(), tripHoldS: 99);
      expect(dashboardFor(trip, (trip: trip, dashboard: server)), same(server));
      final edited = trip.copyWith(title: 'Edited');
      expect(dashboardFor(edited, (trip: trip, dashboard: server)), isNot(same(server)));
      expect(dashboardFor(trip, null).tripHoldS, isNull);
    });
  });
}
