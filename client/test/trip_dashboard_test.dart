// Issue #213 / Story D1 (FR31) with the FR16 time model — the client half of
// the live planning dashboard. `plotlines_core.trips.dashboard.build_dashboard`
// is authoritative and now reachable via `/trips/split`'s `dashboard` block
// ([TripDashboard.fromJson]); [TripDashboard.fromTrip] mirrors the
// distance/elevation roll-up and system-default pace over a locally-assembled
// trip for feedback between saves.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/domain.dart';

Segment _seg(String id, String mode, double distanceM, {double climbM = 0, double descentM = 0}) =>
    Segment(
      id: id,
      mode: mode,
      shape: 'point_to_point',
      metrics: RouteMetrics(distanceM: distanceM, climbM: climbM, descentM: descentM),
    );

Trip _trip(List<Day> days) => Trip(
      id: 'trip-1',
      title: 'Three ways over the range',
      createdAt: '2026-08-31T00:00:00Z',
      updatedAt: '2026-08-31T00:00:00Z',
      days: days,
    );

void main() {
  group('movingTimeSeconds', () {
    test('system-default pace comes from the mode base-speed table', () {
      // hiking 5 km/h → 3600 s for 5 km; cycling 15 km/h → 1200 s for 5 km.
      expect(movingTimeSeconds(5000, 'hiking'), closeTo(3600, 1e-6));
      expect(movingTimeSeconds(5000, 'cycling'), closeTo(1200, 1e-6));
    });

    test('a caller-supplied pace overrides the default, per mode', () {
      expect(movingTimeSeconds(5000, 'hiking', {'hiking': 10.0}), closeTo(1800, 1e-6));
      // a mode absent from the override still falls back to its default
      expect(movingTimeSeconds(5000, 'cycling', {'hiking': 10.0}), closeTo(1200, 1e-6));
    });

    test('a mode with no pace returns null rather than a fabricated one', () {
      expect(movingTimeSeconds(5000, 'transit'), isNull);
      expect(movingTimeSeconds(5000, 'teleportation'), isNull);
      expect(movingTimeSeconds(5000, 'hiking', {'hiking': 0.0}), isNull);
      expect(movingTimeSeconds(5000, 'hiking', {'hiking': -3.0}), isNull);
    });
  });

  group('TripDashboard.fromTrip', () {
    test('rolls distance up by mode and overall, and fills in moving time', () {
      final dash = TripDashboard.fromTrip(_trip([
        Day(id: 'd1', index: 1, segments: [
          _seg('s1', 'cycling', 20000, climbM: 300),
          _seg('s2', 'hiking', 5000, climbM: 400),
        ]),
        Day(id: 'd2', index: 2, segments: [_seg('s3', 'cycling', 30000)]),
      ]));

      expect(dash.paceSource, paceSystemDefault);
      expect(dash.tripTotal.total!.distanceM, 55000);
      expect(dash.tripTotal.byMode['cycling']!.distanceM, 50000);
      expect(dash.tripTotal.byMode['hiking']!.distanceM, 5000);
      expect(dash.tripTotal.total!.climbM, 700);

      // cycling 50 km at 15 km/h = 12000 s; hiking 5 km at 5 km/h = 3600 s.
      expect(dash.tripTotal.byMode['cycling']!.movingTimeS, closeTo(12000, 0.1));
      expect(dash.tripTotal.byMode['hiking']!.movingTimeS, closeTo(3600, 0.1));
      // no holds from a local mirror → elapsed == moving on the scope total
      expect(dash.tripTotal.total!.movingTimeS, closeTo(15600, 0.1));
      expect(dash.tripTotal.total!.elapsedTimeS, closeTo(15600, 0.1));

      // day 1: 20 km cycling (4800 s) + 5 km hiking (3600 s) = 8400 s
      expect(dash.days.first.metrics.total!.movingTimeS, closeTo(8400, 0.1));
      expect(dash.hasTimeModel, isTrue);
    });

    test('a custom pace scales moving time and flips pace_source', () {
      final dash = TripDashboard.fromTrip(
        _trip([
          Day(id: 'd1', index: 1, segments: [_seg('s1', 'cycling', 30000)]),
        ]),
        speeds: {'cycling': 10.0},
      );
      expect(dash.paceSource, paceCustom);
      // 30 km at 10 km/h = 10800 s
      expect(dash.tripTotal.total!.movingTimeS, closeTo(10800, 0.1));
    });

    test('a transit note leg leaves the scope total time null but keeps paced modes', () {
      final dash = TripDashboard.fromTrip(_trip([
        Day(id: 'd1', index: 1, segments: [
          _seg('s1', 'cycling', 10000),
          _seg('s2', 'transit', 40000),
        ]),
      ]));
      expect(dash.tripTotal.byMode['cycling']!.movingTimeS, closeTo(2400, 0.1));
      expect(dash.tripTotal.byMode['transit']!.movingTimeS, isNull);
      expect(dash.tripTotal.total!.movingTimeS, isNull);
      expect(dash.tripTotal.total!.elapsedTimeS, isNull);
      // distance still rolls up across both
      expect(dash.tripTotal.total!.distanceM, 50000);
    });

    test('never sets an ETA — the trip payload carries no start time', () {
      final dash = TripDashboard.fromTrip(_trip([
        Day(id: 'd1', index: 1, segments: [_seg('s1', 'cycling', 10000)]),
      ]));
      expect(dash.tripEta, isNull);
      expect(dash.days.every((d) => d.eta == null), isTrue);
    });

    test('fills the active passage when the id names a segment in the trip', () {
      final dash = TripDashboard.fromTrip(
        _trip([
          Day(id: 'd1', index: 1, segments: [
            _seg('s1', 'cycling', 20000),
            _seg('s2', 'hiking', 5000),
          ]),
        ]),
        activeSegmentId: 's2',
      );
      expect(dash.activePassage, isNotNull);
      expect(dash.activePassage!.segmentId, 's2');
      expect(dash.activePassage!.mode, 'hiking');
      expect(dash.activePassage!.dayIndex, 1);
      expect(dash.activePassage!.metrics.movingTimeS, closeTo(3600, 0.1));
    });

    test('an unknown active-segment id simply leaves the active passage null', () {
      final dash = TripDashboard.fromTrip(
        _trip([
          Day(id: 'd1', index: 1, segments: [_seg('s1', 'cycling', 20000)]),
        ]),
        activeSegmentId: 'nope',
      );
      expect(dash.activePassage, isNull);
    });
  });

  group('TripDashboard.fromJson', () {
    test('decodes the full build_dashboard block including ETA and holds', () {
      final dash = TripDashboard.fromJson({
        'trip_id': 'trip-1',
        'trip_title': 'Server trip',
        'generated_at': '2026-09-01T07:59:00Z',
        'pace_source': 'custom',
        'active_passage': {
          'segment_id': 's2',
          'mode': 'hiking',
          'title': 'Ridge scramble',
          'day_index': 1,
          'metrics': {'distance_m': 5000.0, 'moving_time_s': 3600.0, 'pace_source': 'custom'},
        },
        'days': [
          {
            'day_id': 'd1',
            'index': 1,
            'kind': 'route',
            'metrics': {
              'total': {'distance_m': 25000.0, 'moving_time_s': 8400.0, 'elapsed_time_s': 10200.0},
              'by_mode': {
                'cycling': {'distance_m': 20000.0, 'moving_time_s': 4800.0},
                'hiking': {'distance_m': 5000.0, 'moving_time_s': 3600.0},
              },
            },
            'hold_s': 1800.0,
            'eta': '2026-09-01T10:50:00Z',
          },
        ],
        'trip_total': {
          'total': {'distance_m': 25000.0, 'moving_time_s': 8400.0, 'elapsed_time_s': 10200.0},
          'by_mode': {
            'cycling': {'distance_m': 20000.0, 'moving_time_s': 4800.0},
            'hiking': {'distance_m': 5000.0, 'moving_time_s': 3600.0},
          },
        },
        'trip_hold_s': 1800.0,
        'trip_eta': '2026-09-01T10:50:00Z',
      });

      expect(dash.tripTitle, 'Server trip');
      expect(dash.paceSource, 'custom');
      expect(dash.activePassage!.title, 'Ridge scramble');
      expect(dash.days.single.holdS, 1800.0);
      expect(dash.days.single.eta, '2026-09-01T10:50:00Z');
      expect(dash.tripTotal.total!.elapsedTimeS, 10200.0);
      expect(dash.tripHoldS, 1800.0);
      expect(dash.tripEta, '2026-09-01T10:50:00Z');
      expect(dash.hasTimeModel, isTrue);
    });

    test('decodes the bare distance panel (no time-model inputs on the request)', () {
      final dash = TripDashboard.fromJson({
        'trip_id': 'trip-1',
        'trip_title': 'Bare',
        'generated_at': '2026-09-01T07:59:00Z',
        'pace_source': 'system_default',
        'active_passage': null,
        'days': [
          {
            'day_id': 'd1',
            'index': 1,
            'kind': 'route',
            'metrics': {
              'total': {'distance_m': 1000.0, 'moving_time_s': 240.0},
              'by_mode': {'cycling': {'distance_m': 1000.0, 'moving_time_s': 240.0}},
            },
            'hold_s': null,
            'eta': null,
          },
        ],
        'trip_total': {
          'total': {'distance_m': 1000.0, 'moving_time_s': 240.0},
          'by_mode': {'cycling': {'distance_m': 1000.0, 'moving_time_s': 240.0}},
        },
        'trip_hold_s': null,
        'trip_eta': null,
      });
      expect(dash.activePassage, isNull);
      expect(dash.tripHoldS, isNull);
      expect(dash.tripEta, isNull);
      expect(dash.tripTotal.total!.distanceM, 1000.0);
    });
  });
}
