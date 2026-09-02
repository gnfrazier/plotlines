// E3 / FR39 / FR117 / FR118 (issue #214) — `/days/compose` carries the
// compose-mode places-first views (`itinerary` / `recap` / `cues`) alongside
// the `Day`, the same shape `/trips/split` rides `hazard_rollup` / `dashboard`.
// Before this the client's `composeDay` returned a bare `Day` and had no way to
// reach `compose_itinerary`. A real HTTP round trip against a loopback
// stand-in, because the private decode path can't be reached through a faked
// `RoutingClient`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';

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

Map<String, dynamic> _dayBody({bool withItinerary = true}) => {
      'id': 'day-1',
      'index': 1,
      'kind': 'route',
      'segments': <dynamic>[],
      'transitions': <dynamic>[],
      'metrics': {
        'total': {'distance_m': 8520.0},
      },
      if (withItinerary) ...{
        'itinerary': {
          'planning_mode': 'compose',
          'spine': ['a1', 'a2'],
          'stops': [
            {
              'anchor_id': 'a1',
              'order': 0,
              'title': 'Start',
              'coord': [-105.3, 40.0],
              'roles': ['provision'],
              'arc_stages': <dynamic>[],
              'hazard': false,
              'distance_along_m': 0.0,
              'has_unrevealed_narrative': false,
            },
            {
              'anchor_id': 'a2',
              'order': 1,
              'title': 'End',
              'coord': [-105.2, 40.0],
              'roles': ['narrative'],
              'arc_stages': ['climax'],
              'hazard': false,
              'distance_along_m': 8520.0,
              'has_unrevealed_narrative': false,
            },
          ],
          'legs': [
            {
              'order': 0,
              'segment_id': 'seg-1',
              'mode': 'hiking',
              'distance_m': 8520.0,
              'arc_stage': null,
              'planning_mode': 'compose',
              'hazards': null,
            },
          ],
          'distance': {
            'planning_mode': 'compose',
            'realised_m': 8520.0,
            'target_m': 10000.0,
            'deviation_m': -1480.0,
            'deviation_frac': -0.148,
            'dispositions': ['drop', 'defer', 'split', 'accept'],
            'is_conflict': false,
            'is_error': false,
          },
        },
        'recap': [
          {
            'order': 0,
            'anchor_id': 'a2',
            'title': 'End',
            'arc_stages': ['climax'],
            'distance_along_m': 8520.0,
          },
        ],
        'cues': <dynamic>[],
      },
    };

Anchor _anchor(String id, List<double> coord) => Anchor(
      id: id,
      title: id,
      coord: coord,
      roles: [Role(id: 'r-$id', kind: RoleKind.narrative, reveal: RevealPolicy.alwaysVisible)],
    );

void main() {
  late _FakeSidecar sidecar;
  tearDown(() async => sidecar.stop());

  test('the itinerary / recap / cues block lands on ComposedDay, not on the Day', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(_dayBody);

    final result = await RoutingClient(sidecar.baseUrl).composeDay(
      segments: [Segment(id: 'seg-1', mode: 'hiking', shape: 'point_to_point')],
      anchors: [_anchor('a1', [-105.3, 40.0]), _anchor('a2', [-105.2, 40.0])],
      targetM: 10000.0,
    );

    // the Day still decodes — the extra keys were stripped before Day.fromJson,
    // whose JsonFields.done() would otherwise reject them
    expect(result.day.id, 'day-1');
    expect(result.day.metrics?.total?.distanceM, 8520.0);

    final itin = result.itinerary!;
    expect(itin.spine, ['a1', 'a2']);
    expect(itin.stops.last.distanceAlongM, 8520.0);
    expect(itin.legs.single.mode, 'hiking');
    expect(itin.distance.deviationM, -1480.0);
    expect(itin.distance.isConflict, isFalse);
    expect(itin.recap.single.anchorId, 'a2');

    // the spine and readout target were forwarded on the request body
    expect((sidecar.lastRequestBody!['anchors'] as List).map((a) => a['id']), ['a1', 'a2']);
    expect(sidecar.lastRequestBody!['target_m'], 10000.0);
  });

  test('with no spine the request omits anchors/target_m and itinerary is null', () async {
    sidecar = _FakeSidecar();
    await sidecar.start(() => _dayBody(withItinerary: false));

    final result = await RoutingClient(sidecar.baseUrl).composeDay(
      segments: [Segment(id: 'seg-1', mode: 'hiking', shape: 'point_to_point')],
    );

    expect(result.day.id, 'day-1');
    expect(result.itinerary, isNull);
    expect(sidecar.lastRequestBody!.containsKey('anchors'), isFalse);
    expect(sidecar.lastRequestBody!.containsKey('target_m'), isFalse);
  });
}
