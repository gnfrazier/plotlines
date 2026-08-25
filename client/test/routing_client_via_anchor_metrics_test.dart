// Story A9 (issue #26) — "a genuine loop rather than an out-and-back, with
// any road ridden twice reported." `service/plotlines_service/app.py`'s
// `_loop_to_dict` now sends `overlap_frac`/`overlap_near_frac`/
// `overlap_far_frac` alongside the loop-family response's existing flat
// fields (`shape`/`closed`/`hit_via`/`target_m`); this pins that
// `RoutingClient._segmentFromSolveResponse` actually reads them onto the
// domain `Segment.metrics`, the same way `current_trip_provider_generate_
// target_distance_test.dart` pins `target_m`'s own parsing — that file fakes
// `RoutingClient` itself, which is exactly what cannot exercise the private
// parser this story touches, so this one runs a real HTTP round trip against
// a local stand-in server instead (the pattern `vector_tile_provider_test
// .dart` already established for the sidecar's tile endpoint).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';

class _FakeSidecar {
  late HttpServer _server;
  String get baseUrl => 'http://127.0.0.1:${_server.port}';
  Map<String, dynamic>? lastRequest;

  Future<void> start(Map<String, dynamic> Function() responseBody) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      lastRequest = body.isEmpty ? null : jsonDecode(body) as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(responseBody()));
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

Map<String, dynamic> _loopResponse({
  double overlapFrac = 0.08,
  double overlapNearFrac = 0.06,
  double overlapFarFrac = 0.02,
}) => {
      'mode': 'cycling',
      'theme': 'balanced',
      'distance_m': 12000.0,
      'coordinates': [
        [-105.28, 40.02],
        [-105.27, 40.03],
      ],
      'elevation': {},
      'node_count': 2,
      'solve_ms': 5.0,
      'geometry_wkt': '',
      'shape': 'loop',
      'closed': true,
      'hit_via': true,
      'target_m': 12000.0,
      'distance_error': 0.0,
      'overlap_frac': overlapFrac,
      'overlap_near_frac': overlapNearFrac,
      'overlap_far_frac': overlapFarFrac,
    };

void main() {
  late _FakeSidecar sidecar;

  tearDown(() async {
    await sidecar.stop();
  });

  test('a via-anchor loop response parses the overlap split onto Segment.metrics', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(_loopResponse);
    final client = RoutingClient(sidecar.baseUrl);

    final segment = await client.generateSegment(
      region: 'region-1',
      start: const [-105.28, 40.02],
      via: const [
        [-105.275, 40.02],
        [-105.29, 40.01],
      ],
      shape: 'loop',
      targetM: 12000.0,
    );

    expect(segment.metrics!.overlapFrac, 0.08);
    expect(segment.metrics!.overlapNearFrac, 0.06);
    expect(segment.metrics!.overlapFarFrac, 0.02);
    expect(segment.solve!.closed, true);
    expect(segment.solve!.hitVia, true);
  });

  test('the via-anchors themselves are sent to the sidecar in order', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(_loopResponse);
    final client = RoutingClient(sidecar.baseUrl);

    await client.generateSegment(
      region: 'region-1',
      start: const [-105.28, 40.02],
      via: const [
        [-105.275, 40.02],
        [-105.29, 40.01],
      ],
      shape: 'loop',
      targetM: 12000.0,
    );

    final sentVia = sidecar.lastRequest!['via'] as List;
    expect(sentVia.length, 2);
    expect(sentVia[0], {'lat': 40.02, 'lon': -105.275});
    expect(sentVia[1], {'lat': 40.01, 'lon': -105.29});
  });

  test('a point_to_point response with no overlap fields leaves them null, not zero', () async {
    // Point-to-point's response family (`Segment.to_dict()`, `solve.py`)
    // never carries overlap fields at all — this must read as "unknown",
    // never as an honest 0.0 the segment did not earn.
    sidecar = _FakeSidecar();
    await sidecar.start(() => {
          'mode': 'cycling',
          'theme': 'balanced',
          'distance_m': 5000.0,
          'shape': 'point_to_point',
          'coordinates': [
            [-105.28, 40.02],
            [-105.27, 40.03],
          ],
          'elevation': {},
          'node_count': 2,
          'solve_ms': 5.0,
          'geometry_wkt': '',
        });
    final client = RoutingClient(sidecar.baseUrl);

    final segment = await client.generateSegment(
      region: 'region-1',
      start: const [-105.28, 40.02],
      end: const [-105.27, 40.03],
      shape: 'point_to_point',
    );

    expect(segment.metrics!.overlapFrac, isNull);
    expect(segment.metrics!.overlapNearFrac, isNull);
    expect(segment.metrics!.overlapFarFrac, isNull);
  });
}
