// Issue #496 (ARCH §8.6/D66's client half) — every `RoutingClient` sidecar
// call below `geocode` (already fixed by #493, covered in
// `routing_client_endpoints_test.dart`) now carries a deadline and converts
// a `TimeoutException` into a [RoutingException] with an honest sentence.
// Before this, a wedged sidecar thread left these calls waiting forever with
// nothing for the surrounding `on RoutingException catch` / M13 plumbing to
// catch — `weights_rail.dart` and `new_route_screen.dart` both display
// `RoutingException.message` directly, so a raw `TimeoutException` reaching
// them would have shown as an unhandled error or a stack-trace string.
//
// A real loopback `HttpServer` that never responds, matching the pattern
// #493's own regression test uses for `geocode`. Each mutable static
// timeout is shrunk to milliseconds so the suite doesn't wait out the real
// deadlines.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';

Future<(RoutingClient, HttpServer)> _hungSidecar() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  // Deliberately never responds — a stand-in for a wedged sidecar thread,
  // worse than any real slow solve/build.
  server.listen((request) {});
  return (RoutingClient('http://127.0.0.1:${server.port}'), server);
}

Segment _segment() => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.2797, 40.0175],
      end: const [-105.275, 40.02],
    );

void main() {
  group('RoutingClient sidecar-call timeouts', () {
    test('health times out with the honest sentence, not a bare hang', () async {
      final (client, _) = await _hungSidecar();
      final saved = RoutingClient.healthTimeout;
      RoutingClient.healthTimeout = const Duration(milliseconds: 50);
      addTearDown(() => RoutingClient.healthTimeout = saved);

      await expectLater(
        client.health,
        throwsA(
          isA<RoutingException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', contains("didn't answer")),
        ),
      );
    });

    test('about times out with the honest sentence, not a bare hang', () async {
      final (client, _) = await _hungSidecar();
      final saved = RoutingClient.aboutTimeout;
      RoutingClient.aboutTimeout = const Duration(milliseconds: 50);
      addTearDown(() => RoutingClient.aboutTimeout = saved);

      await expectLater(
        client.about,
        throwsA(
          isA<RoutingException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', contains("didn't answer")),
        ),
      );
    });

    // Issue #492 gave `POST /regions` its own server-side per-phase
    // deadline; this is the client's own bound on the 202 response itself
    // never arriving (a wedged shared-pool thread before the build is even
    // queued). Never rendered raw either way (`TripRegionFailed`'s error is
    // logged, not shown — issue #230 B3) but other `ensureRegion` call
    // sites (`weights_rail.dart`) do catch `on RoutingException` around it.
    test('ensureRegion times out with the honest sentence, not a bare hang', () async {
      final (client, _) = await _hungSidecar();
      final saved = RoutingClient.ensureRegionTimeout;
      RoutingClient.ensureRegionTimeout = const Duration(milliseconds: 50);
      addTearDown(() => RoutingClient.ensureRegionTimeout = saved);

      await expectLater(
        () => client.ensureRegion(const [-105.3, 40.0, -105.2, 40.1]),
        throwsA(
          isA<RoutingException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', contains("didn't answer")),
        ),
      );
    });

    test('generateSegment times out with the honest sentence, not a bare hang', () async {
      final (client, _) = await _hungSidecar();
      final saved = RoutingClient.generateSegmentTimeout;
      RoutingClient.generateSegmentTimeout = const Duration(milliseconds: 50);
      addTearDown(() => RoutingClient.generateSegmentTimeout = saved);

      await expectLater(
        () => client.generateSegment(
          region: 'region-1',
          start: const [-105.2797, 40.0175],
          end: const [-105.275, 40.02],
          shape: 'point_to_point',
        ),
        throwsA(
          isA<RoutingException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', contains("didn't answer")),
        ),
      );
    });

    test('envelope times out with the honest sentence, not a bare hang', () async {
      final (client, _) = await _hungSidecar();
      final saved = RoutingClient.envelopeTimeout;
      RoutingClient.envelopeTimeout = const Duration(milliseconds: 50);
      addTearDown(() => RoutingClient.envelopeTimeout = saved);

      await expectLater(
        () => client.envelope(
          region: 'region-1',
          start: const [-105.2797, 40.0175],
          targetM: 20000,
        ),
        throwsA(
          isA<RoutingException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', contains("didn't answer")),
        ),
      );
    });

    test('submitDiagnose times out with the honest sentence, not a bare hang', () async {
      final (client, _) = await _hungSidecar();
      final saved = RoutingClient.submitDiagnoseTimeout;
      RoutingClient.submitDiagnoseTimeout = const Duration(milliseconds: 50);
      addTearDown(() => RoutingClient.submitDiagnoseTimeout = saved);

      await expectLater(
        () => client.submitDiagnose(
          region: 'region-1',
          start: const [-105.2797, 40.0175],
          targetM: 20000,
          bands: [Band(attribute: 'climbing_m', min: 100, max: 400)],
        ),
        throwsA(
          isA<RoutingException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', contains("didn't answer")),
        ),
      );
    });

    test('pollDiagnose times out with the honest sentence, not a bare hang', () async {
      final (client, _) = await _hungSidecar();
      final saved = RoutingClient.pollDiagnoseTimeout;
      RoutingClient.pollDiagnoseTimeout = const Duration(milliseconds: 50);
      addTearDown(() => RoutingClient.pollDiagnoseTimeout = saved);

      await expectLater(
        () => client.pollDiagnose('job-1'),
        throwsA(
          isA<RoutingException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', contains("didn't answer")),
        ),
      );
    });

    test('cuesFor times out with the honest sentence, not a bare hang', () async {
      final (client, _) = await _hungSidecar();
      final saved = RoutingClient.cuesForTimeout;
      RoutingClient.cuesForTimeout = const Duration(milliseconds: 50);
      addTearDown(() => RoutingClient.cuesForTimeout = saved);

      await expectLater(
        () => client.cuesFor(_segment(), region: 'region-1'),
        throwsA(
          isA<RoutingException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', contains("didn't answer")),
        ),
      );
    });

    test('composeDay times out with the honest sentence, not a bare hang', () async {
      final (client, _) = await _hungSidecar();
      final saved = RoutingClient.composeDayTimeout;
      RoutingClient.composeDayTimeout = const Duration(milliseconds: 50);
      addTearDown(() => RoutingClient.composeDayTimeout = saved);

      await expectLater(
        () => client.composeDay(segments: [_segment()]),
        throwsA(
          isA<RoutingException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', contains("didn't answer")),
        ),
      );
    });

    test('assembleTrip times out with the honest sentence, not a bare hang', () async {
      final (client, _) = await _hungSidecar();
      final saved = RoutingClient.assembleTripTimeout;
      RoutingClient.assembleTripTimeout = const Duration(milliseconds: 50);
      addTearDown(() => RoutingClient.assembleTripTimeout = saved);

      await expectLater(
        () => client.assembleTrip(days: const [], title: 'Test trip'),
        throwsA(
          isA<RoutingException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', contains("didn't answer")),
        ),
      );
    });
  });
}
