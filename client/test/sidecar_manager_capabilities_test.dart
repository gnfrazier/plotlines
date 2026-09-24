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

    test('a provisional capability (issue #432) is ready but flagged, never failed', () {
      final status = CapabilityStatus.fromJson({
        'ready': true,
        'provisional': true,
        'reason': 'offline — routing on a locally truncated copy ...',
      });
      expect(status.ready, isTrue);
      expect(status.provisional, isTrue);
      expect(status.failed, isFalse);
    });

    test('provisional defaults to false for every other capability shape', () {
      expect(CapabilityStatus.fromJson({'ready': true}).provisional, isFalse);
      expect(
        CapabilityStatus.fromJson({'ready': false, 'reason': 'failed:x'}).provisional,
        isFalse,
      );
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

    test('a provisional capability describes with the sidecar\'s own reason, not "ready"', () {
      const status = CapabilityStatus(
        ready: true,
        provisional: true,
        reason: 'offline — will rebuild for real once reconnected',
      );
      final text = status.describe('Routing');
      expect(text, 'offline — will rebuild for real once reconnected');
      expect(text, isNot('Routing ready'));
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

    test('forRegion surfaces a provisional region distinctly from ready (issue #432)', () {
      final caps = Capabilities.fromJson(healthBody(
        regions: {
          'shrunk1': {
            'ready': true,
            'provisional': true,
            'reason': 'offline — will rebuild once reconnected',
          },
        },
        elevation: {'ready': false, 'reason': 'elevation_source_not_configured:tracked_in_148'},
      ));
      final region = caps.routing.forRegion('shrunk1')!;
      expect(region.ready, isTrue);
      expect(region.provisional, isTrue);
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

  group('Capabilities.mirror (issue #367)', () {
    Map<String, dynamic> body(Map<String, dynamic>? mirror) => {
          'tiles': {'ready': true},
          'layers': {'ready': true},
          'routing': {'regions': <String, dynamic>{}},
          'elevation': {'ready': false, 'reason': 'x'},
          if (mirror != null) 'mirror': mirror,
        };

    test('absent mirror key reads as not-configured, not fresh', () {
      final caps = Capabilities.fromJson(body(null));
      expect(caps.mirror.configured, isFalse);
      expect(caps.mirror.stale, isFalse);
    });

    test('configured: false reads the same as absent', () {
      final caps = Capabilities.fromJson(body({'configured': false}));
      expect(caps.mirror.configured, isFalse);
    });

    test('a fresh mirror parses basemap age and geofabrik staleness', () {
      final caps = Capabilities.fromJson(body({
        'configured': true,
        'stale': false,
        'basemap': {'build_id': '20250101-wnc', 'age_days': 3.2, 'stale': false},
        'geofabrik': {'pinned_date': '2026-09-01', 'regions': {}, 'stale': false},
      }));
      expect(caps.mirror.configured, isTrue);
      expect(caps.mirror.stale, isFalse);
      expect(caps.mirror.basemapAgeDays, 3.2);
      expect(caps.mirror.geofabrikStale, isFalse);
      expect(caps.mirror.error, isNull);
    });

    test('a stale mirror is loud (§11.3 — a stopped cron reads as loud, not silent)', () {
      final caps = Capabilities.fromJson(body({
        'configured': true,
        'stale': true,
        'basemap': {'build_id': '20250101-wnc', 'age_days': 52.0, 'stale': true},
        'geofabrik': {'pinned_date': '2026-07-01', 'regions': {}, 'stale': false},
      }));
      expect(caps.mirror.stale, isTrue);
      expect(caps.mirror.basemapAgeDays, 52.0);
    });

    test('a fetch failure reports stale with the error, never a silent unknown', () {
      final caps = Capabilities.fromJson(body({
        'configured': true,
        'stale': true,
        'error': 'URLError: unreachable',
      }));
      expect(caps.mirror.configured, isTrue);
      expect(caps.mirror.stale, isTrue);
      expect(caps.mirror.error, 'URLError: unreachable');
    });
  });

  group('Capabilities.tilesUpstream (issue #454)', () {
    Map<String, dynamic> body(Map<String, dynamic>? upstream) => {
          'tiles': {
            'ready': true,
            'archive': 'a1b2c3',
            if (upstream != null) 'upstream': upstream,
          },
          'layers': {'ready': true},
          'routing': {'regions': <String, dynamic>{}},
          'elevation': {'ready': false, 'reason': 'x'},
        };

    test('absent upstream key (an older sidecar) is null, not a default kind', () {
      final caps = Capabilities.fromJson(body(null));
      expect(caps.tilesUpstream, isNull);
      // #155's byte-identical fields are untouched either way.
      expect(caps.tilesArchiveId, 'a1b2c3');
    });

    test('a local archive parses kind/source with refused false', () {
      final caps = Capabilities.fromJson(body({
        'kind': 'local',
        'source': '/opt/plotlines/home.pmtiles',
        'refused': false,
        'reason': null,
      }));
      expect(caps.tilesUpstream!.kind, 'local');
      expect(caps.tilesUpstream!.source, '/opt/plotlines/home.pmtiles');
      expect(caps.tilesUpstream!.refused, isFalse);
      expect(caps.tilesUpstream!.reason, isNull);
    });

    test('upstream bounds are null until the sidecar has read them (issue #154)', () {
      final caps = Capabilities.fromJson(body({
        'kind': 'mirror',
        'source': 'https://tiles.plotlines.app/basemap/protomaps/x/y.pmtiles',
        'refused': false,
        'reason': null,
        'bounds': null,
      }));
      expect(caps.tilesUpstream!.bounds, isNull);
    });

    test('upstream bounds parse as [west, south, east, north] doubles (issue #154)', () {
      final caps = Capabilities.fromJson(body({
        'kind': 'mirror',
        'source': 'https://tiles.plotlines.app/basemap/protomaps/x/y.pmtiles',
        'refused': false,
        'reason': null,
        'bounds': [-83.6, 35.2, -81, 36.4],
      }));
      expect(caps.tilesUpstream!.bounds, [-83.6, 35.2, -81.0, 36.4]);
    });

    test('the mirror host parses kind mirror, never refused', () {
      final caps = Capabilities.fromJson(body({
        'kind': 'mirror',
        'source': 'https://tiles.plotlines.app/basemap/protomaps/x/y.pmtiles',
        'refused': false,
        'reason': null,
      }));
      expect(caps.tilesUpstream!.kind, 'mirror');
      expect(caps.tilesUpstream!.refused, isFalse);
    });

    test('a foreign host reports refused true with a named reason (FR92/FR95)', () {
      final caps = Capabilities.fromJson(body({
        'kind': 'foreign',
        'source': 'https://tile.openstreetmap.org/x.pmtiles',
        'refused': true,
        'reason': "tile upstream 'tile.openstreetmap.org' is not the Plotlines "
            'mirror (tiles.plotlines.app): Plotlines mirrors the Protomaps '
            'basemap rather than hotlinking a third-party tile host (FR92/FR95).',
      }));
      expect(caps.tilesUpstream!.kind, 'foreign');
      expect(caps.tilesUpstream!.refused, isTrue);
      expect(caps.tilesUpstream!.reason, contains('FR92/FR95'));
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
