// Issue #209 / Story A11 (FR128) — every `/segments/generate` response shape
// carries `surfaced_constraints`: the mode-legal but noteworthy edges a route
// rolls over (`bicycle=dismount`, `barrier=gate`, `ford=yes`, …), filled
// server-side by `routing.access.flags_along_walk`. The client used to read
// `coordinates`/`elevation`/`overlap_*`/`hit_via` off the flat response and
// drop this list on the floor. This pins that
// `RoutingClient._segmentFromSolveResponse` now lands it on
// `Segment.surfacedConstraints` — a real HTTP round trip against a local
// stand-in, the same pattern `routing_client_via_anchor_metrics_test.dart`
// uses, because the private parser cannot be exercised through a faked
// `RoutingClient`.

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

Map<String, dynamic> _pointToPointResponse({List<dynamic>? surfacedConstraints}) => {
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
      'surfaced_constraints': ?surfacedConstraints,
    };

void main() {
  late _FakeSidecar sidecar;

  tearDown(() async {
    await sidecar.stop();
  });

  test('surfaced_constraints on the response land on Segment.surfacedConstraints in order', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(() => _pointToPointResponse(surfacedConstraints: [
          {'from': 101, 'to': 102, 'flags': ['bicycle=dismount']},
          {'from': 102, 'to': 205, 'flags': ['barrier=gate', 'ford=yes']},
        ]));
    final client = RoutingClient(sidecar.baseUrl);

    final segment = await client.generateSegment(
      region: 'region-1',
      start: const [-105.28, 40.02],
      end: const [-105.27, 40.03],
      shape: 'point_to_point',
    );

    expect(segment.surfacedConstraints, hasLength(2));
    expect(segment.surfacedConstraints[0].from, 101);
    expect(segment.surfacedConstraints[0].to, 102);
    expect(segment.surfacedConstraints[0].flags, ['bicycle=dismount']);
    expect(segment.surfacedConstraints[1].from, 102);
    expect(segment.surfacedConstraints[1].to, 205);
    expect(segment.surfacedConstraints[1].flags, ['barrier=gate', 'ford=yes']);
  });

  test('a response with an empty surfaced_constraints list leaves the segment list empty', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(() => _pointToPointResponse(surfacedConstraints: const []));
    final client = RoutingClient(sidecar.baseUrl);

    final segment = await client.generateSegment(
      region: 'region-1',
      start: const [-105.28, 40.02],
      end: const [-105.27, 40.03],
      shape: 'point_to_point',
    );

    expect(segment.surfacedConstraints, isEmpty);
  });

  test('a response with no surfaced_constraints key at all leaves the segment list empty', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(_pointToPointResponse);
    final client = RoutingClient(sidecar.baseUrl);

    final segment = await client.generateSegment(
      region: 'region-1',
      start: const [-105.28, 40.02],
      end: const [-105.27, 40.03],
      shape: 'point_to_point',
    );

    expect(segment.surfacedConstraints, isEmpty);
  });
}
