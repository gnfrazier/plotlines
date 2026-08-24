// M12a — per-capability readiness (ARCH §8.3, PRD FR121). Covers the pure
// parsing/derivation logic `SidecarManager` builds on: `CapabilityStatus`
// and `Capabilities` decoding a `/health` response, `.describe()`'s honest
// wording for a disabled control, and `.settled` gating when the
// capability-watch loop stops polling.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/sidecar_manager.dart';

void main() {
  group('CapabilityStatus.fromJson', () {
    test('a ready capability carries no reason/progress/eta', () {
      final status = CapabilityStatus.fromJson({'ready': true});
      expect(status.ready, isTrue);
      expect(status.reason, isNull);
      expect(status.progress, isNull);
      expect(status.etaS, isNull);
      expect(status.failed, isFalse);
    });

    test('a loading capability carries reason, progress and eta', () {
      final status = CapabilityStatus.fromJson({
        'ready': false,
        'reason': 'elevation_enriching',
        'progress': 0.42,
        'eta_s': 180.0,
      });
      expect(status.ready, isFalse);
      expect(status.reason, 'elevation_enriching');
      expect(status.progress, 0.42);
      expect(status.etaS, 180.0);
      expect(status.failed, isFalse);
    });

    test('a failed capability is recognized by its reason prefix', () {
      final status = CapabilityStatus.fromJson({
        'ready': false,
        'reason': 'failed:FileNotFoundError: no DEM at dem.tif',
      });
      expect(status.ready, isFalse);
      expect(status.failed, isTrue);
    });
  });

  group('CapabilityStatus.describe', () {
    test('ready reads as ready', () {
      const status = CapabilityStatus(ready: true);
      expect(status.describe('Routing'), 'Routing ready');
    });

    test('loading with an eta gives an honest wait, never a bare spinner', () {
      const status = CapabilityStatus(
        ready: false,
        reason: 'elevation_enriching',
        progress: 0.42,
        etaS: 180,
      );
      final text = status.describe('Routing');
      expect(text, contains('loading'));
      expect(text, contains('available in'));
      expect(text, contains('3 minutes'));
    });

    test('a one-minute eta reads as "about a minute", not "about 1 minutes"', () {
      const status = CapabilityStatus(ready: false, reason: 'graph_loading', etaS: 45);
      expect(status.describe('Routing'), contains('about a minute'));
    });

    test('a failure with no eta names the reason rather than a wait', () {
      const status = CapabilityStatus(ready: false, reason: 'failed:disk full');
      final text = status.describe('Elevation');
      expect(text, contains('unavailable'));
      expect(text, contains('failed:disk full'));
      expect(text, isNot(contains('available in')));
    });
  });

  group('Capabilities.fromJson / settled', () {
    Map<String, dynamic> healthBody({
      required Map<String, dynamic> routing,
      required Map<String, dynamic> elevation,
    }) => {
          'tiles': {'ready': true},
          'layers': {'ready': true, 'per_layer': {'historic': 'ready'}},
          'routing': routing,
          'elevation': elevation,
        };

    test('tiles/layers ready immediately even while routing/elevation load', () {
      final caps = Capabilities.fromJson(healthBody(
        routing: {'ready': false, 'reason': 'elevation_enriching', 'progress': 0.1, 'eta_s': 300},
        elevation: {'ready': false, 'reason': 'opening elevation', 'progress': 0.1, 'eta_s': 300},
      ));
      expect(caps.tiles.ready, isTrue);
      expect(caps.layers.ready, isTrue);
      expect(caps.routing.ready, isFalse);
      expect(caps.elevation.ready, isFalse);
      expect(caps.settled, isFalse);
    });

    test('settled once both routing and elevation are ready', () {
      final caps = Capabilities.fromJson(healthBody(
        routing: {'ready': true},
        elevation: {'ready': true},
      ));
      expect(caps.settled, isTrue);
    });

    test('settled if elevation failed but routing still came up (never blocks forever)', () {
      final caps = Capabilities.fromJson(healthBody(
        routing: {'ready': true},
        elevation: {'ready': false, 'reason': 'failed:no DEM at dem.tif'},
      ));
      expect(caps.routing.ready, isTrue);
      expect(caps.elevation.failed, isTrue);
      expect(caps.settled, isTrue);
    });

    test('not settled while either capability is still actively loading', () {
      final caps = Capabilities.fromJson(healthBody(
        routing: {'ready': false, 'reason': 'graph_loading', 'progress': 0.5, 'eta_s': 3},
        elevation: {'ready': false, 'reason': 'failed:no DEM'},
      ));
      expect(caps.settled, isFalse);
    });
  });
}
