// Issue #627 — a solved passage's `elevation.samples` (per-vertex, index-aligned
// with `coordinates`) is what the metrics rail's `ElevationProfile` draws. The
// sidecar never sent them and `RoutingClient._segmentFromSolveResponse` never
// read them, so every passage read "No elevation profile for this passage
// yet." This pins the parse — a real HTTP round trip against a local stand-in,
// the same pattern `routing_client_surfaced_constraints_test.dart` uses,
// because the private parser cannot be exercised through a faked client.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';

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

Map<String, dynamic> _response(Map<String, dynamic> elevation) => {
      'mode': 'cycling',
      'theme': 'balanced',
      'distance_m': 5000.0,
      'shape': 'point_to_point',
      'coordinates': [
        [-105.28, 40.02],
        [-105.275, 40.025],
        [-105.27, 40.03],
      ],
      'elevation': elevation,
      'node_count': 3,
      'solve_ms': 5.0,
      'geometry_wkt': '',
    };

void main() {
  late _FakeSidecar sidecar;

  tearDown(() async {
    await sidecar.stop();
  });

  Future<Elevation?> solve() async {
    final segment = await RoutingClient(sidecar.baseUrl).generateSegment(
      region: 'region-1',
      start: const [-105.28, 40.02],
      end: const [-105.27, 40.03],
      shape: 'point_to_point',
    );
    return segment.elevation;
  }

  test('samples and void_samples land on Segment.elevation, index-aligned', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(() => _response({
          'ascent_m': 40.0, 'descent_m': 0.0, 'min_m': 1600.0, 'max_m': 1640.0,
          'samples': [1600, 1620.5, 1640.0],
          'void_samples': 1,
        }));

    final elevation = await solve();

    expect(elevation!.samples, [1600.0, 1620.5, 1640.0]);
    expect(elevation.voidSamples, 1);
    expect(elevation.ascentM, 40.0);
    // and it survives the payload round trip the trip is saved through
    expect(elevation.toJson()['samples'], [1600.0, 1620.5, 1640.0]);
  });

  test('a route with no elevation source parses to an empty sample list', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(() => _response({}));

    final elevation = await solve();

    expect(elevation!.samples, isEmpty);
    expect(elevation.voidSamples, isNull);
  });
}
