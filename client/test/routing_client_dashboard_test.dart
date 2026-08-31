// Issue #213 / Story D1 (FR31, FR16) — `/trips/split` carries the live planning
// `dashboard` alongside the assembled trip payload, the same shape `hazard_rollup`
// (#210) and `surfaced_constraints` (#209) ride. Before this the client's
// `assembleTrip` had no way to reach `build_dashboard`'s moving-time / ETA model
// at all. A real HTTP round trip against a loopback stand-in, because the private
// decode path cannot be reached through a faked `RoutingClient`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/data/routing_client.dart';

class _FakeSidecar {
  late HttpServer _server;
  String get baseUrl => 'http://127.0.0.1:${_server.port}';
  Map<String, dynamic>? lastRequestBody;

  Future<void> start(Map<String, dynamic> Function() responseBody) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      lastRequestBody = raw.isEmpty ? null : jsonDecode(raw) as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(responseBody()));
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

Map<String, dynamic> _tripBody({Map<String, dynamic>? dashboard}) => {
      'schema_version': '1.6.0',
      'id': 'trip-1',
      'title': 'Assembled trip',
      'created_at': '2026-08-31T00:00:00Z',
      'updated_at': '2026-08-31T00:00:00Z',
      'days': <dynamic>[],
      'dashboard': ?dashboard,
    };

Map<String, dynamic> _dashboardBlock() => {
      'trip_id': 'trip-1',
      'trip_title': 'Assembled trip',
      'generated_at': '2026-09-01T07:59:00Z',
      'pace_source': 'custom',
      'active_passage': null,
      'days': [
        {
          'day_id': 'd1',
          'index': 1,
          'kind': 'route',
          'metrics': {
            'total': {'distance_m': 30000.0, 'moving_time_s': 10800.0, 'elapsed_time_s': 12600.0},
            'by_mode': {'cycling': {'distance_m': 30000.0, 'moving_time_s': 10800.0}},
          },
          'hold_s': 1800.0,
          'eta': '2026-09-01T11:30:00Z',
        },
      ],
      'trip_total': {
        'total': {'distance_m': 30000.0, 'moving_time_s': 10800.0, 'elapsed_time_s': 12600.0},
        'by_mode': {'cycling': {'distance_m': 30000.0, 'moving_time_s': 10800.0}},
      },
      'trip_hold_s': 1800.0,
      'trip_eta': '2026-09-01T11:30:00Z',
    };

void main() {
  late _FakeSidecar sidecar;

  tearDown(() async {
    await sidecar.stop();
  });

  test('the dashboard block on /trips/split lands on AssembledTrip', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(() => _tripBody(dashboard: _dashboardBlock()));

    final result = await RoutingClient(sidecar.baseUrl).assembleTrip(
      days: const [],
      title: 'x',
      speeds: {'cycling': 10.0},
      dayHoldS: {'d1': 1800.0},
      tripStartAt: '2026-09-01T08:00:00Z',
    );

    expect(result.trip.id, 'trip-1');
    expect(result.dashboard, isNotNull);
    expect(result.dashboard!.paceSource, 'custom');
    expect(result.dashboard!.tripTotal.total!.movingTimeS, 10800.0);
    expect(result.dashboard!.tripEta, '2026-09-01T11:30:00Z');
    expect(result.dashboard!.days.single.holdS, 1800.0);

    // the time-model inputs are forwarded on the request body
    expect(sidecar.lastRequestBody!['speeds'], {'cycling': 10.0});
    expect(sidecar.lastRequestBody!['day_hold_s'], {'d1': 1800.0});
    expect(sidecar.lastRequestBody!['trip_start_at'], '2026-09-01T08:00:00Z');
  });

  test('with no time-model inputs the request omits those keys entirely', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(() => _tripBody(dashboard: _dashboardBlock()));

    await RoutingClient(sidecar.baseUrl).assembleTrip(days: const [], title: 'x');

    expect(sidecar.lastRequestBody!.containsKey('speeds'), isFalse);
    expect(sidecar.lastRequestBody!.containsKey('day_hold_s'), isFalse);
    expect(sidecar.lastRequestBody!.containsKey('trip_start_at'), isFalse);
    expect(sidecar.lastRequestBody!.containsKey('active_segment_id'), isFalse);
  });

  test('an older sidecar that omits dashboard yields a null dashboard, not a throw', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(_tripBody);

    final result = await RoutingClient(sidecar.baseUrl).assembleTrip(days: const [], title: 'x');

    expect(result.trip.id, 'trip-1');
    expect(result.dashboard, isNull);
  });
}
