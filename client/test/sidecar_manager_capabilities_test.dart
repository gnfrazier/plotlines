// M12a — per-capability readiness (ARCH §8.3, PRD FR121); per-region routing
// readiness (issue #154). Covers the pure parsing/derivation logic
// `SidecarManager` builds on: `CapabilityStatus` and `Capabilities` decoding
// a `/health` response, `.describe()`'s honest wording for a disabled
// control, `RoutingCapability.forRegion`, and `.failed`'s generalized
// "stopped trying" rule.
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

    test('a failed capability (no progress) reads as stopped trying', () {
      final status = CapabilityStatus.fromJson({
        'ready': false,
        'reason': 'failed:FileNotFoundError: no DEM at dem.tif',
      });
      expect(status.ready, isFalse);
      expect(status.failed, isTrue);
    });

    test('a fixed not-configured reason (no failed: prefix) also reads as stopped trying', () {
      // Issue #154's elevation capability: never a failure, never going to
      // load, and carries no `progress` — the same "stop waiting" signal.
      final status = CapabilityStatus.fromJson({
        'ready': false,
        'reason': 'elevation_source_not_configured:tracked_in_148',
      });
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

  group('Capabilities.fromJson / RoutingCapability', () {
    Map<String, dynamic> healthBody({
      required Map<String, dynamic> regions,
      required Map<String, dynamic> elevation,
    }) => {
          'tiles': {'ready': true},
          'layers': {'ready': true, 'per_layer': {'historic': 'ready'}},
          'routing': {'regions': regions},
          'elevation': elevation,
        };

    test('tiles/layers ready immediately even with no region ensured yet', () {
      final caps = Capabilities.fromJson(healthBody(
        regions: {},
        elevation: {'ready': false, 'reason': 'elevation_source_not_configured:tracked_in_148'},
      ));
      expect(caps.tiles.ready, isTrue);
      expect(caps.layers.ready, isTrue);
      expect(caps.routing.regions, isEmpty);
      expect(caps.elevation.ready, isFalse);
    });

    test('forRegion looks up one region by key', () {
      final caps = Capabilities.fromJson(healthBody(
        regions: {
          'abc123': {'ready': false, 'reason': 'graph_loading', 'progress': 0.5, 'eta_s': 3},
          'def456': {'ready': true},
        },
        elevation: {'ready': false, 'reason': 'elevation_source_not_configured:tracked_in_148'},
      ));
      expect(caps.routing.forRegion('abc123')!.ready, isFalse);
      expect(caps.routing.forRegion('def456')!.ready, isTrue);
    });

    test('forRegion is null for an unensured key, distinct from not-ready', () {
      final caps = Capabilities.fromJson(healthBody(
        regions: {},
        elevation: {'ready': false, 'reason': 'elevation_source_not_configured:tracked_in_148'},
      ));
      expect(caps.routing.forRegion('never-ensured'), isNull);
      expect(caps.routing.forRegion(null), isNull);
    });

    test('elevation is settled (stopped trying) even though it never becomes ready', () {
      // Issue #154's explicit scoping note: elevation acquisition is gated
      // on FR87 (#148) and is never attempted for any region.
      final caps = Capabilities.fromJson(healthBody(
        regions: {'abc123': {'ready': true}},
        elevation: {'ready': false, 'reason': 'elevation_source_not_configured:tracked_in_148'},
      ));
      expect(caps.elevation.ready, isFalse);
      expect(caps.elevation.failed, isTrue);
      expect(caps.settled, isTrue);
    });
  });
}
