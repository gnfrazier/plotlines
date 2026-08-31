// Issue #210 / Story C11 (FR27, FR115) — `/trips/split` carries `hazard_rollup`
// alongside the assembled trip payload: the one traversal of every hazard the
// trip holds, plus the worst-first sync-alert subset the client raises as an
// interrupt on trip open. Before this the client's `assembleTrip` decoded the
// payload and dropped that block on the floor (the same shape of bug #209
// fixed for `surfaced_constraints`).
//
// A real HTTP round trip against a loopback stand-in — the same pattern
// `routing_client_surfaced_constraints_test.dart` uses — because the private
// decode path cannot be reached through a faked `RoutingClient`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/data/routing_client.dart';

class _FakeSidecar {
  late HttpServer _server;
  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> start(Map<String, dynamic> Function() responseBody) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      await utf8.decoder.bind(request).join();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(responseBody()));
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

Map<String, dynamic> _tripBody({Map<String, dynamic>? hazardRollup}) => {
      'schema_version': '1.6.0',
      'id': 'trip-1',
      'title': 'Assembled trip',
      'created_at': '2026-08-31T00:00:00Z',
      'updated_at': '2026-08-31T00:00:00Z',
      'days': <dynamic>[],
      'hazard_rollup': ?hazardRollup,
    };

void main() {
  late _FakeSidecar sidecar;

  tearDown(() async {
    await sidecar.stop();
  });

  test('hazard_rollup on the /trips/split response lands on AssembledTrip', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(() => _tripBody(hazardRollup: {
          'has_sync_alerts': true,
          'sync_alerts': [
            {
              'hazard_id': 'h-bridge',
              'severity': 'mandatory_reroute',
              'day_index': 2,
              'scope': 'passage',
              'title': 'Bridge out',
              'safety_note': 'Use the FS-19 detour.',
              'segment_id': 's2',
            },
            {
              'hazard_id': 'h-guard',
              'severity': 'high',
              'day_index': 1,
              'scope': 'passage',
              'title': 'Cattle guard',
              'segment_id': 's1',
            },
          ],
          'hazards': [
            {
              'hazard': {'id': 'h-grit', 'severity': 'caution', 'title': 'Loose gravel'},
              'scope': 'day',
              'day_index': 1,
              'day_id': 'd1',
            },
            {
              'hazard': {'id': 'h-guard', 'severity': 'high', 'title': 'Cattle guard'},
              'scope': 'passage',
              'day_index': 1,
              'day_id': 'd1',
              'segment_id': 's1',
            },
            {
              'hazard': {'id': 'h-bridge', 'severity': 'mandatory_reroute', 'title': 'Bridge out'},
              'scope': 'passage',
              'day_index': 2,
              'day_id': 'd2',
              'segment_id': 's2',
            },
          ],
        }));

    final result = await RoutingClient(sidecar.baseUrl).assembleTrip(days: const [], title: 'x');

    expect(result.trip.id, 'trip-1');
    expect(result.hazardRollup.hasSyncAlerts, isTrue);
    expect(result.hazardRollup.syncAlerts.map((a) => a.title), ['Bridge out', 'Cattle guard']);
    expect(result.hazardRollup.hazards.map((h) => h.hazard.title),
        ['Loose gravel', 'Cattle guard', 'Bridge out']);
  });

  test('an older sidecar that omits hazard_rollup yields an empty roll-up, not a throw', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(_tripBody);

    final result = await RoutingClient(sidecar.baseUrl).assembleTrip(days: const [], title: 'x');

    expect(result.trip.id, 'trip-1');
    expect(result.hazardRollup.hasSyncAlerts, isFalse);
    expect(result.hazardRollup.hazards, isEmpty);
    expect(result.hazardRollup.syncAlerts, isEmpty);
  });
}
