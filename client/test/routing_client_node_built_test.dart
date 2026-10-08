// Issue #653 — the request half: a passage built from nodes (#626) has no
// stored `start`, and `cuesFor` re-solves from the ends its Generate used
// (`routeSolveInputs`). And Diagnose's poll has a deadline.
//
// A real loopback `HttpServer`, like `routing_client_endpoints_test.dart`,
// so these stay plain `test`s: a widget test's binding answers every HTTP
// request with a 400.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';

const _a = [-79.50, 36.10];
const _b = [-79.45, 36.12];
const _c = [-79.40, 36.15];

Segment _nodeBuilt() => Segment(
      id: 'nodes',
      mode: 'cycling',
      shape: 'point_to_point',
      via: const [_a, _b, _c],
      nodes: [
        Node(id: 'n1', kind: NodeKind.start, coord: _a, title: 'Gazebo'),
        Node(id: 'n2', kind: NodeKind.restStop, coord: _b, title: 'Park'),
        Node(id: 'n3', kind: NodeKind.finish, coord: _c, title: 'Downtown'),
      ],
    );

class _FakeSidecar {
  late HttpServer _server;
  String get baseUrl => 'http://127.0.0.1:${_server.port}';
  final requests = <String>[];
  Map<String, dynamic>? lastBody;
  Object Function(HttpRequest) respond = (_) => {};

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      requests.add(request.uri.path);
      final raw = await utf8.decoder.bind(request).join();
      lastBody = raw.isEmpty ? null : jsonDecode(raw) as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(respond(request)));
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

Map<String, double> _ll(List<double> c) => {'lat': c[1], 'lon': c[0]};

void main() {
  group('RoutingClient.cuesFor', () {
    late _FakeSidecar sidecar;
    setUp(() async {
      sidecar = _FakeSidecar();
      await sidecar.start();
      sidecar.respond = (_) => {'cue_sheet': {'generated_at': '2026-10-08T00:00:00Z', 'cues': []}};
    });
    tearDown(() => sidecar.stop());

    test('a passage built from nodes re-solves from its start node to its finish node', () async {
      await RoutingClient(sidecar.baseUrl).cuesFor(_nodeBuilt(), region: 'region-1');

      final body = sidecar.lastBody!;
      expect(body['start'], _ll(_a));
      expect(body['end'], _ll(_c));
      expect(body['via'], [_ll(_b)]);
    });

    test('a passage with nothing to route between raises a typed error and sends nothing',
        () async {
      final bare = Segment(id: 'bare', mode: 'cycling', shape: 'point_to_point');
      await expectLater(RoutingClient(sidecar.baseUrl).cuesFor(bare, region: 'region-1'),
          throwsA(isA<RoutingException>()));
      expect(sidecar.requests, isEmpty);
    });
  });

  group('RoutingClient.awaitDiagnosis', () {
    late _FakeSidecar sidecar;
    final limit = RoutingClient.diagnoseWaitLimit;
    final interval = RoutingClient.diagnosePollInterval;
    setUp(() async {
      sidecar = _FakeSidecar();
      await sidecar.start();
      RoutingClient.diagnoseWaitLimit = const Duration(milliseconds: 150);
      RoutingClient.diagnosePollInterval = const Duration(milliseconds: 20);
    });
    tearDown(() async {
      RoutingClient.diagnoseWaitLimit = limit;
      RoutingClient.diagnosePollInterval = interval;
      await sidecar.stop();
    });

    test('a job that stays pending gives up with a sentence, not a spin', () async {
      sidecar.respond = (_) => {'status': 'pending'};
      final error = await RoutingClient(sidecar.baseUrl)
          .awaitDiagnosis('job-1')
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<RoutingException>());
      expect((error as RoutingException).reason, contains('diagnosing the route'));
      expect(sidecar.requests.length, greaterThan(1));
    });
  });

}
