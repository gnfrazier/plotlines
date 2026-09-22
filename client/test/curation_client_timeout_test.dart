// Issue #496 (ARCH §8.6/D66's client half) — every `CurationClient` sidecar
// call now carries a deadline and converts a `TimeoutException` into a
// [CurationException] with an honest sentence, matching the shape #493
// shipped for `RoutingClient.geocode`. Before this, a wedged sidecar thread
// (any of #490/#491/#494's companion defects, or a future one) left these
// calls waiting forever with no M13 state to show — `TripCandidatesNotifier`
// is "a no-op while a run is already in flight", so a hung `/candidates`
// blocked every later extraction attempt for the session too.
//
// A real loopback `HttpServer` that never responds, not a faked client —
// the point is the actual `.timeout()` firing, which a stubbed transport
// can't exercise. Each mutable static timeout is shrunk to milliseconds so
// the suite doesn't wait out the real deadlines.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/curation_client.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';

Future<(CurationClient, HttpServer)> _hungSidecar() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  // Deliberately never responds — a stand-in for a wedged sidecar thread,
  // worse than any real slow extraction/clustering pass.
  server.listen((request) {});
  return (CurationClient('http://127.0.0.1:${server.port}'), server);
}

void main() {
  group('CurationClient sidecar-call timeouts', () {
    test('layerCatalog times out with the honest sentence, not a bare hang', () async {
      final (client, _) = await _hungSidecar();
      final saved = CurationClient.layerCatalogTimeout;
      CurationClient.layerCatalogTimeout = const Duration(milliseconds: 50);
      addTearDown(() => CurationClient.layerCatalogTimeout = saved);

      await expectLater(
        () => client.layerCatalog(mode: 'cycling', dayType: 'route'),
        throwsA(
          isA<CurationException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', contains("didn't answer")),
        ),
      );
    });

    test('scoreCandidates times out with the honest sentence, not a bare hang', () async {
      final (client, _) = await _hungSidecar();
      final saved = CurationClient.scoreCandidatesTimeout;
      CurationClient.scoreCandidatesTimeout = const Duration(milliseconds: 50);
      addTearDown(() => CurationClient.scoreCandidatesTimeout = saved);

      await expectLater(
        () => client.scoreCandidates(liveLayers: const {'sight'}, features: const []),
        throwsA(
          isA<CurationException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', contains("didn't answer")),
        ),
      );
    });

    test('candidatesForBbox times out with the honest sentence, not a bare hang', () async {
      final (client, _) = await _hungSidecar();
      final saved = CurationClient.candidatesTimeout;
      CurationClient.candidatesTimeout = const Duration(milliseconds: 50);
      addTearDown(() => CurationClient.candidatesTimeout = saved);

      const bbox = TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.1, maxLon: -105.2);
      await expectLater(
        () => client.candidatesForBbox(bbox: bbox, liveLayers: const {'sight'}),
        throwsA(
          isA<CurationException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', contains("didn't answer")),
        ),
      );
    });

    // Issue #504 — `/clusters/analyze` runs the same extraction `/candidates`
    // does but (unlike `/candidates` since #490) with no server-side
    // deadline of its own yet, so this is the client's only bound today.
    test('analyzeColocation times out with the honest sentence, not a bare hang', () async {
      final (client, _) = await _hungSidecar();
      final saved = CurationClient.analyzeColocationTimeout;
      CurationClient.analyzeColocationTimeout = const Duration(milliseconds: 50);
      addTearDown(() => CurationClient.analyzeColocationTimeout = saved);

      const bbox = TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.1, maxLon: -105.2);
      await expectLater(
        () => client.analyzeColocation(bbox: bbox, liveLayers: const {'sight'}),
        throwsA(
          isA<CurationException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', contains("didn't answer")),
        ),
      );
    });
  });
}
