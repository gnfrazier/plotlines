// #235 B6 — the `RoutingClient` methods no test had ever called.
//
// `routing_client.dart` sat at 49.8%, with `health()`, `about()`, `geocode()`,
// `pollDiagnose()`, `cuesFor()` and `GeocodeResult.fromJson` entirely
// unexercised. `cuesFor` is the sharpest of those: FR133/F1's amenity-to-cue
// path is verified end to end on the service side by
// `test_cue_provisions_endpoint.py`, and was verified nowhere at all on the
// client side — neither the request it builds nor the `CueSheet` it decodes.
//
// A real loopback `HttpServer` rather than a faked client, matching
// `routing_client_dashboard_test.dart`: the request bodies and the private
// decode paths are the point, and a stubbed `RoutingClient` would skip both.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';

class _FakeSidecar {
  late HttpServer _server;
  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  final requests = <String>[];
  Map<String, dynamic>? lastBody;
  Map<String, String> lastQuery = const {};

  Future<void> start(
    Object Function(HttpRequest request) responseBody, {
    int status = 200,
  }) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      requests.add(request.uri.path);
      lastQuery = request.uri.queryParameters;
      final raw = await utf8.decoder.bind(request).join();
      lastBody = raw.isEmpty ? null : jsonDecode(raw) as Map<String, dynamic>;
      final body = responseBody(request);
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(body is String ? body : jsonEncode(body));
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

Future<(RoutingClient, _FakeSidecar)> _client(
  Object Function(HttpRequest) body, {
  int status = 200,
}) async {
  final sidecar = _FakeSidecar();
  await sidecar.start(body, status: status);
  addTearDown(sidecar.stop);
  return (RoutingClient(sidecar.baseUrl), sidecar);
}

Segment _segment() => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.2797, 40.0175],
      end: const [-105.275, 40.02],
      via: const [
        [-105.277, 40.018]
      ],
      weights: WeightProfile(name: 'balanced'),
      targetDistance: TargetDistance(valueM: 20000),
      nodes: [
        Node(
          id: 'n1',
          kind: NodeKind.restStop,
          coord: const [-105.277, 40.018],
          distanceAlongM: 100,
          title: 'Overlook Camp',
          instructions: 'Fill up here.',
          amenities: const ['water', 'toilets'],
        ),
      ],
      hazards: [
        Hazard(
          id: 'h1',
          severity: 'high',
          coord: const [-105.276, 40.019],
          distanceAlongM: 250,
          title: 'Weir',
          safetyNote: 'Portage river left.',
        ),
      ],
      portages: [
        Portage(
          id: 'p1',
          geometry: LineString(coordinates: const [
            [-105.276, 40.019]
          ]),
          exitBank: 'river_left',
          mandatory: true,
          distanceM: 120,
        ),
      ],
      alternates: [
        Alternate(
          id: 'a1',
          kind: 'variant',
          intent: 'branch',
          geometry: LineString(coordinates: const [
            [-105.2755, 40.0195]
          ]),
          label: 'Gravel variant',
          divergesAtM: 200,
        ),
      ],
    );

Map<String, dynamic> _cueSheetBody() => {
      'cue_sheet': {
        'generated_at': '2026-09-02T00:00:00Z',
        'generator': 'plotlines-core cues/1.0',
        'derived_from': {
          'segment_ids': ['seg-1'],
          'geometry_digest': 'dg1',
        },
        'cues': [
          {
            'id': 'cue-0',
            'sequence': 0,
            'distance_along_m': 0.0,
            'kind': 'start',
            'instruction': 'Start',
          },
          {
            'id': 'cue-1',
            'sequence': 1,
            'distance_along_m': 100.0,
            'kind': 'provision',
            'instruction': 'Rest stop: Overlook Camp — water, toilets',
            'ref_id': 'n1',
          },
          {
            'id': 'cue-2',
            'sequence': 2,
            'distance_along_m': 250.0,
            'kind': 'hazard',
            'instruction': 'Weir — portage river left',
            'ref_id': 'h1',
          },
        ],
      },
      'stats': {'cues': 3},
    };

void main() {
  group('health', () {
    test('returns the capability block the sidecar reports', () async {
      final (client, sidecar) = await _client((_) => {
            'status': 'ok',
            'capabilities': {
              'routing': {'regions': <String, dynamic>{}},
            },
          });

      final health = await client.health();

      expect(sidecar.requests.single, '/health');
      expect(health['status'], 'ok');
      expect(health['capabilities'], isA<Map>());
    });

    test('a sidecar error surfaces as a RoutingException', () async {
      final (client, _) = await _client((_) => {'detail': 'not ready'}, status: 503);

      await expectLater(client.health(), throwsA(isA<RoutingException>()));
    });
  });

  group('about', () {
    test('carries the licence obligations the About surface renders', () async {
      // K10/K11 (FR86, FR95): a missing attribution is a build failure, not a
      // polish item — so the transport for it needs a test.
      final (client, sidecar) = await _client((_) => {
            'attribution': [
              {
                'source': 'osm',
                'licence': 'ODbL',
                'credit': '© OpenStreetMap contributors',
                'url': 'https://osm.org/copyright',
              },
            ],
            'app_version': '0.0.1',
            'sidecar_version': '0.0.1',
            'privacy': 'Plotlines keeps your trips on your machine.',
          });

      final about = await client.about();

      expect(sidecar.requests.single, '/about');
      expect((about['attribution'] as List), hasLength(1));
      expect((about['attribution'] as List).first['licence'], 'ODbL');
      expect(about['privacy'], isNotEmpty);
    });
  });

  group('geocode', () {
    test('passes the query and decodes each result', () async {
      final (client, sidecar) = await _client((_) => {
            'results': [
              {
                'label': 'Lyons, Colorado',
                'coord': [-105.2705, 40.2247],
                'bbox': [-105.29, 40.21, -105.25, 40.24],
              },
              {
                'label': 'Lyons, France',
                'coord': [4.8357, 45.764],
              },
            ],
          });

      final results = await client.geocode('Lyons');

      expect(sidecar.lastQuery['q'], 'Lyons');
      expect(results, hasLength(2));
      expect(results.first.label, 'Lyons, Colorado');
      expect(results.first.coord, [-105.2705, 40.2247]);
      expect(results.first.bbox, [-105.29, 40.21, -105.25, 40.24]);
    });

    test('a result with no bounding box decodes with a null bbox', () async {
      // FR96: the bbox only ever frames the map — it never becomes the trip
      // bbox — so its absence has to be representable rather than fatal.
      final (client, _) = await _client((_) => {
            'results': [
              {'label': 'Somewhere', 'coord': [0.0, 0.0]},
            ],
          });

      expect((await client.geocode('x')).single.bbox, isNull);
    });

    test('an empty result list is not an error', () async {
      final (client, _) = await _client((_) => {'results': <dynamic>[]});

      expect(await client.geocode('nowhere at all'), isEmpty);
    });

    test('a query with spaces and punctuation survives the URL', () async {
      final (client, sidecar) = await _client((_) => {'results': <dynamic>[]});

      await client.geocode('Saint-Étienne, Loire');

      expect(sidecar.lastQuery['q'], 'Saint-Étienne, Loire');
    });
  });

  group('pollDiagnose', () {
    test('returns null while the job is still running', () async {
      // A6 step 2 of 2. Null is "not yet", not "no conflict" — a caller that
      // read a pending poll as a finished one would report a feasible route.
      final (client, sidecar) = await _client((_) => {'status': 'pending'});

      expect(await client.pollDiagnose('job-1'), isNull);
      expect(sidecar.requests.single, '/segments/diagnose/job-1');
    });

    test('decodes the finished diagnosis', () async {
      final (client, _) = await _client((_) => {
            'status': 'done',
            'diagnosis': {
              'feasible': false,
              'kind': 'band_conflict',
              'conflict': ['climb_m'],
              'explanation': 'climb_m cannot be met inside the distance band',
              'relaxations': [
                {
                  'metric': 'climb_m',
                  'from': 'at least 600 m',
                  'to': 'at least 420 m',
                  'reached_by': 'quiet',
                  'trade_off': 'more traffic',
                },
              ],
              'solves': 12,
              'elapsed_ms': 4120.5,
            },
          });

      final diagnosis = await client.pollDiagnose('job-1');

      expect(diagnosis, isNotNull);
      expect(diagnosis!.feasible, isFalse);
      expect(diagnosis.conflict, ['climb_m']);
      expect(diagnosis.relaxations.single.metric, 'climb_m');
      expect(diagnosis.solves, 12);
    });

    test('a job that failed server-side raises rather than reading as pending',
        () async {
      final (client, _) =
          await _client((_) => {'detail': 'graph disappeared'}, status: 500);

      await expectLater(
          client.pollDiagnose('job-1'), throwsA(isA<RoutingException>()));
    });
  });

  group('cuesFor', () {
    test('asks the sidecar to re-derive against the graph', () async {
      // "re-solved server-side against the graph rather than trusted from
      // client geometry" — the routing inputs have to be in the request.
      final (client, sidecar) = await _client((_) => _cueSheetBody());

      await client.cuesFor(_segment(), region: 'region-1');

      expect(sidecar.requests.single, '/segments/cues');
      final body = sidecar.lastBody!;
      expect(body['region'], 'region-1');
      expect(body['segment_id'], 'seg-1');
      expect(body['shape'], 'point_to_point');
      expect(body['theme'], 'balanced');
      expect(body['target_m'], 20000);
      expect(body['start'], {'lat': 40.0175, 'lon': -105.2797});
      expect(body['end'], {'lat': 40.02, 'lon': -105.275});
      expect(body['via'], [
        {'lat': 40.018, 'lon': -105.277}
      ]);
    });

    test('a node\'s amenities ride along to be woven server-side', () async {
      // FR133 / F1 / C5. The service side of this is pinned by
      // `test_cue_provisions_endpoint.py`; this is the half that sends them.
      final (client, sidecar) = await _client((_) => _cueSheetBody());

      await client.cuesFor(_segment(), region: 'region-1');

      final node = (sidecar.lastBody!['nodes'] as List).single;
      expect(node['id'], 'n1');
      expect(node['kind'], 'rest_stop');
      expect(node['amenities'], ['water', 'toilets']);
      expect(node['instructions'], 'Fill up here.');
    });

    test('hazards, portages and alternates all reach the request', () async {
      final (client, sidecar) = await _client((_) => _cueSheetBody());

      await client.cuesFor(_segment(), region: 'region-1');

      final body = sidecar.lastBody!;
      expect((body['hazards'] as List).single['safety_note'],
          'Portage river left.');
      expect((body['portages'] as List).single['exit_bank'], 'river_left');
      expect((body['portages'] as List).single['mandatory'], isTrue);
      expect((body['alternates'] as List).single['label'], 'Gravel variant');
    });

    test('decodes the sheet, its provenance and every cue', () async {
      // `CueSheet.fromJson` had never run in a test — including the nested
      // `derived_from` object, which is the only place `segment_ids` and
      // `geometry_digest` live.
      final (client, _) = await _client((_) => _cueSheetBody());

      final sheet = await client.cuesFor(_segment(), region: 'region-1');

      expect(sheet.generatedAt, '2026-09-02T00:00:00Z');
      expect(sheet.generator, 'plotlines-core cues/1.0');
      expect(sheet.derivedFromSegmentIds, ['seg-1']);
      expect(sheet.derivedFromGeometryDigest, 'dg1');
      expect(sheet.cues, hasLength(3));
      expect(sheet.cues.map((c) => c.kind),
          ['start', 'provision', 'hazard']);
      expect(sheet.cues[1].instruction,
          'Rest stop: Overlook Camp — water, toilets');
      expect(sheet.cues[2].refId, 'h1');
    });

    test('a sidecar refusal surfaces its own message', () async {
      // M13/A6: FastAPI's `{"detail": ...}` is the text an Author reads.
      final (client, _) =
          await _client((_) => {'detail': 'region not ready'}, status: 422);

      await expectLater(
        client.cuesFor(_segment(), region: 'region-1'),
        throwsA(isA<RoutingException>()
            .having((e) => e.message, 'message', contains('region not ready'))
            .having((e) => e.statusCode, 'statusCode', 422)),
      );
    });
  });
}
