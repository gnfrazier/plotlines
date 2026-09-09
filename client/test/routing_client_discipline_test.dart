// Issue #315 — `discipline` rides the `/segments/generate` and
// `/segments/cues` request bodies when a passage carries one, and the value
// the server echoes lands back on `Segment.discipline`. A real HTTP round
// trip against a local stand-in (same pattern as
// `routing_client_surfaced_constraints_test.dart`), because the private
// parser cannot be exercised through a faked `RoutingClient`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';

class _FakeSidecar {
  late HttpServer _server;
  Map<String, dynamic>? lastBody;
  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> start(Map<String, dynamic> Function() responseBody) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      lastBody = raw.isEmpty ? null : jsonDecode(raw) as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(responseBody()));
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

Map<String, dynamic> _response({String? discipline}) => {
      'mode': 'cycling',
      'theme': 'balanced',
      if (discipline != null) 'discipline': discipline,
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
    };

void main() {
  late _FakeSidecar sidecar;
  tearDown(() async => sidecar.stop());

  test('discipline rides the generate body and comes back on the segment', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(() => _response(discipline: 'mountain'));
    final client = RoutingClient(sidecar.baseUrl);

    final segment = await client.generateSegment(
      region: 'region-1',
      start: const [-105.28, 40.02],
      end: const [-105.27, 40.03],
      mode: 'cycling',
      discipline: 'mountain',
      shape: 'point_to_point',
    );

    expect(sidecar.lastBody!['discipline'], 'mountain');
    expect(segment.discipline, 'mountain');
  });

  test('no discipline means no discipline key on the wire', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(_response);
    final client = RoutingClient(sidecar.baseUrl);

    final segment = await client.generateSegment(
      region: 'region-1',
      start: const [-105.28, 40.02],
      end: const [-105.27, 40.03],
      shape: 'point_to_point',
    );

    expect(sidecar.lastBody!.containsKey('discipline'), isFalse);
    expect(segment.discipline, isNull);
  });

  test('cuesFor carries the passage discipline', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(() => const <String, dynamic>{});
    final client = RoutingClient(sidecar.baseUrl);

    // We only care that the request body carried `discipline`; the empty
    // response is deliberately unparseable, so swallow the decode error.
    try {
      await client.cuesFor(
        Segment(
          id: 's1', mode: 'cycling', discipline: 'gravel', shape: 'point_to_point',
          start: const [-105.28, 40.02], end: const [-105.27, 40.03],
        ),
        region: 'region-1',
      );
    } catch (_) {}

    expect(sidecar.lastBody!['discipline'], 'gravel');
  });
}
