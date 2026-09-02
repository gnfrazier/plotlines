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
      expect(text, contains('disk full'));
      expect(text, isNot(contains('available in')));
    });

    test('the sidecar\'s "failed:" reason prefix is stripped for display (issue #229)', () {
      const status = CapabilityStatus(
        ready: false,
        reason: 'failed:Couldn\'t reach the map-data service to prepare routing '
            'for this area.',
      );
      final text = status.describe('Routing');
      expect(text, isNot(contains('failed:')));
      expect(
        text,
        'Routing unavailable — Couldn\'t reach the map-data service to prepare '
        'routing for this area.',
      );
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

    test('tiles.archive is surfaced as tilesArchiveId, null when absent (issue #155)', () {
      final withArchive = Capabilities.fromJson({
        'tiles': {'ready': true, 'archive': 'a1b2c3d4e5f60718'},
        'layers': {'ready': true, 'per_layer': {'historic': 'ready'}},
        'routing': {'regions': <String, dynamic>{}},
        'elevation': {'ready': false, 'reason': 'x'},
      });
      expect(withArchive.tilesArchiveId, 'a1b2c3d4e5f60718');

      final olderSidecar = Capabilities.fromJson(healthBody(
        regions: {},
        elevation: {'ready': false, 'reason': 'x'},
      ));
      expect(olderSidecar.tilesArchiveId, isNull);
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

  group('SidecarManager.healthPollTimeout (Buncombe County incident)', () {
    Capabilities caps(Map<String, dynamic> regions) => Capabilities.fromJson({
          'tiles': {'ready': true},
          'layers': {'ready': true},
          'routing': {'regions': regions},
          'elevation': {'ready': false, 'reason': 'x'},
        });

    test('baseline 2s when nothing is building', () {
      expect(SidecarManager.healthPollTimeout(null), const Duration(seconds: 2));
      expect(SidecarManager.healthPollTimeout(caps({})), const Duration(seconds: 2));
      expect(
        SidecarManager.healthPollTimeout(caps({'a': {'ready': true}})),
        const Duration(seconds: 2),
      );
    });

    test('widens to 8s while a region graph is still building', () {
      // A CPU-bound OSMnx build in the sidecar process can starve the
      // trivial `/health` handler of the GIL for a second or two; a poll
      // that spuriously times out during a legitimate build used to leave
      // the UI on a stale snapshot.
      final building = caps({
        'a': {'ready': false, 'reason': 'graph_loading', 'progress': 0.3, 'eta_s': 40},
      });
      expect(SidecarManager.healthPollTimeout(building), const Duration(seconds: 8));
    });

    test('a failed region (no progress) does not widen the timeout', () {
      final failed = caps({
        'a': {'ready': false, 'reason': 'failed:Overpass 504'},
      });
      expect(SidecarManager.healthPollTimeout(failed), const Duration(seconds: 2));
    });

    test('one building region among several ready ones is enough to widen', () {
      final mixed = caps({
        'a': {'ready': true},
        'b': {'ready': false, 'reason': 'graph_loading', 'progress': 0.9, 'eta_s': 5},
      });
      expect(SidecarManager.healthPollTimeout(mixed), const Duration(seconds: 8));
    });
  });

  group('Capabilities per-layer readiness (story N2)', () {
    Map<String, dynamic> body(Map<String, dynamic> layers) => {
          'tiles': {'ready': true},
          'layers': layers,
          'routing': {'regions': <String, dynamic>{}},
          'elevation': {'ready': false, 'reason': 'x'},
        };

    test('per_layer and per_layer_detail are parsed', () {
      final caps = Capabilities.fromJson(body({
        'ready': true,
        'per_layer': {
          'historic': 'ready',
          'revwar_battlefields': 'loading',
          'plugin_manors': 'failed:licence_unsatisfiable',
        },
        'per_layer_detail': {
          'revwar_battlefields': {'state': 'loading', 'progress': 0.4, 'elapsed_s': 2.1},
        },
      }));
      expect(caps.layerState('historic'), 'ready');
      expect(caps.layerState('revwar_battlefields'), 'loading');
      expect(caps.layerState('plugin_manors'), 'failed:licence_unsatisfiable');
      expect(caps.layerState('unknown'), isNull);
      expect(caps.layersPerLayerDetail['revwar_battlefields'], isNotNull);
    });

    test('layerReady defaults an unreported layer to ready', () {
      final caps = Capabilities.fromJson(body({'ready': true, 'per_layer': {'historic': 'ready'}}));
      expect(caps.layerReady('historic'), isTrue);
      expect(caps.layerReady('amenity'), isTrue); // unreported -> ready
    });

    test('layerReady is false for a loading or failed layer', () {
      final caps = Capabilities.fromJson(body({
        'ready': true,
        'per_layer': {'a': 'loading', 'b': 'failed:boom'},
      }));
      expect(caps.layerReady('a'), isFalse);
      expect(caps.layerReady('b'), isFalse);
    });

    test('layers.ready reads the any-flag: true with a failed plugin present', () {
      final caps = Capabilities.fromJson(body({
        'ready': true, // sidecar computes any(), not all()
        'per_layer': {'historic': 'ready', 'plugin_manors': 'failed:licence_unsatisfiable'},
      }));
      expect(caps.layers.ready, isTrue);
    });

    test('a health body with no per_layer key is tolerated', () {
      final caps = Capabilities.fromJson(body({'ready': true}));
      expect(caps.layersPerLayer, isEmpty);
      expect(caps.layerReady('anything'), isTrue);
    });
  });
}
