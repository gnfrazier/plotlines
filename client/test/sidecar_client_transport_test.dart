// Issue #496's rule — "no TimeoutException or SocketException reaches a
// catch block that displays `.message`" — held for timeouts only. A sidecar
// that is dead, restarting, or degraded refuses the connection, and
// `package:http` raises a `ClientException` for that: it escaped every
// `on RoutingException catch` (`weights_rail.dart`'s regenerate, New Route's
// search) as an unhandled error, and New Route's generic `catch (e)` put
// `ClientException with SocketException: Connection refused … port = …` on
// screen. And `message` returned a non-sentence body verbatim — FastAPI's
// 422 validation list, a traceback.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/curation_client.dart';
import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';

/// A loopback URL with nothing listening — what a client sees while the
/// sidecar is down.
Future<String> _deadSidecarUrl() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return 'http://127.0.0.1:$port';
}

const _bbox = TripBbox(minLat: 39.9, minLon: -105.4, maxLat: 40.1, maxLon: -105.1);

void main() {
  group('a refused connection is a typed, honest 503', () {
    test('RoutingClient.generateSegment', () async {
      final client = RoutingClient(await _deadSidecarUrl());
      await expectLater(
        client.generateSegment(region: 'r', start: const [-105.2, 40.0], targetM: 1000),
        throwsA(isA<RoutingException>()
            .having((e) => e.statusCode, 'statusCode', 503)
            .having((e) => e.message, 'message', contains("couldn't be reached"))
            .having((e) => e.message, 'message', isNot(contains('127.0.0.1')))),
      );
    });

    test('RoutingClient.geocode', () async {
      final client = RoutingClient(await _deadSidecarUrl());
      await expectLater(
        client.geocode('Asheville'),
        throwsA(isA<RoutingException>()
            .having((e) => e.message, 'message', contains("couldn't be reached"))),
      );
    });

    test('CurationClient.candidatesForBbox', () async {
      final client = CurationClient(await _deadSidecarUrl());
      await expectLater(
        client.candidatesForBbox(bbox: _bbox, liveLayers: {'sight'}),
        throwsA(isA<CurationException>()
            .having((e) => e.statusCode, 'statusCode', 503)
            .having((e) => e.message, 'message', contains("couldn't be reached"))),
      );
    });
  });

  // RoutingException.message is shown as-is (New Route, the weights rail);
  // CurationException's callers apply their own guard, see its doc comment.
  group('RoutingException.message never returns a diagnostic body verbatim', () {
    const validation = '{"detail":[{"type":"missing","loc":["body","region"],'
        '"msg":"Field required","input":{}}]}';

    test('a 422 validation list', () {
      expect(RoutingException(422, validation).message, 'Request failed (422)');
    });

    test('a traceback body', () {
      const trace = 'Traceback (most recent call last):\n  File "app.py", line 1';
      expect(RoutingException(500, trace).message, 'Request failed (500)');
    });

    test('the sidecar\'s own detail sentence and a plain status line pass through', () {
      expect(RoutingException(409, '{"detail":"that day is locked"}').message,
          'that day is locked');
      expect(RoutingException(500, 'Internal Server Error').message, 'Internal Server Error');
    });
  });
}
