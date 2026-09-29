// Issue #522 (epic #516, ARCH D67) — the client's waiting state while the
// Plotlines mirror fetches an area. The sidecar reports `pending_upstream`
// (#521) on routing, extract, tiles and elevation, and answers a filling
// basemap cell's tiles `503` + `Retry-After`. Each has to read as a wait —
// distinct from a failure and from out-of-coverage — and clear on its own.
// The tile provider's half is in `vector_tile_provider_test.dart`, which
// runs real loopback HTTP (a widget test's binding here would stub it).

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/presentation/map/no_basemap_notice.dart';
import 'package:plotlines_client/presentation/widgets/error_states.dart';

/// `CapabilityState.to_dict()`'s `pending_upstream` shape (service
/// `app.py::_pending_upstream_dict`), verbatim.
const _routingWaiting = {
  'ready': false,
  'reason': 'The map-data mirror is fetching OSM data for this area from Geofabrik.',
  'pending_upstream': true,
  'progress': 0.0,
  'fill_id': 'osm-cell-1d-36-80',
  'retry_after_s': 30,
  'waiting_s': 185,
};

Map<String, dynamic> _health({
  Map<String, dynamic> routing = _routingWaiting,
  Map<String, dynamic>? tilesRegion,
  Map<String, dynamic>? extractRegion,
}) =>
    {
      'tiles': {
        'ready': true,
        'archive': 'abc',
        if (tilesRegion != null) 'regions': {'r1': tilesRegion},
      },
      'layers': {'ready': true},
      'routing': {
        'regions': {'r1': routing},
      },
      'elevation': {'ready': true},
      if (extractRegion != null)
        'extract': {
          'configured': true,
          'regions': {'r1': extractRegion},
        },
    };

Widget _host(Widget child) => MaterialApp(
      theme: PlotTheme.light(),
      home: Scaffold(body: Center(child: SizedBox(width: 480, child: child))),
    );

void main() {
  group('Capabilities.fromJson parses pending_upstream per capability', () {
    test('routing: a wait with its fill, poll hint and observed wait', () {
      final caps = Capabilities.fromJson(_health());
      final routing = caps.routing.forRegion('r1')!;
      expect(routing.pendingUpstream, isTrue);
      expect(routing.fillId, 'osm-cell-1d-36-80');
      expect(routing.retryAfterS, 30);
      expect(routing.waitingS, 185);
      // A wait, never a stop — no screen may offer a retry for it.
      expect(routing.failed, isFalse);
      expect(routing.ready, isFalse);
    });

    test('tiles.regions carries each filling cell; the map reads their union', () {
      final caps = Capabilities.fromJson(_health(tilesRegion: {
        'ready': false,
        'reason': 'The map-data mirror is fetching the basemap for this area.',
        'pending_upstream': true,
        'progress': 0.0,
        'fill_id': 'basemap-cell-2d',
        'cells': [
          [-80, 36, -78, 38],
        ],
      }));
      expect(caps.tilesFor('r1')!.pendingUpstream, isTrue);
      expect(caps.fillingTileCells, [
        [-80.0, 36.0, -78.0, 38.0],
      ]);
    });

    test('a ready tiles region contributes no filling cells', () {
      final caps = Capabilities.fromJson(_health(tilesRegion: {'ready': true}));
      expect(caps.fillingTileCells, isEmpty);
    });

    test('extract.regions reads the mirror\'s terminal no-coverage answer', () {
      final caps = Capabilities.fromJson(
          _health(extractRegion: {'ready': false, 'reason': 'failed:no_upstream_coverage'}));
      final extract = caps.extractFor('r1')!;
      expect(extract.noUpstreamCoverage, isTrue);
      expect(extract.pendingUpstream, isFalse);
    });

    test('an older sidecar with no tiles/extract regions still parses', () {
      final caps = Capabilities.fromJson(_health(routing: {'ready': true}));
      expect(caps.tilesRegions, isEmpty);
      expect(caps.extractRegions, isEmpty);
      expect(caps.fillingTileCells, isEmpty);
    });

    test('a waiting region does not widen the /health poll timeout', () {
      // Nothing builds in the sidecar's process while it waits on a fill.
      final waiting = Capabilities.fromJson(_health());
      final building = Capabilities.fromJson(_health(
          routing: {'ready': false, 'reason': 'building graph', 'progress': 0.4}));
      expect(SidecarManager.healthPollTimeout(waiting),
          lessThan(SidecarManager.healthPollTimeout(building)));
    });
  });

  group('describe() names the mirror', () {
    test('a wait says the mirror is getting the data, and how long so far', () {
      final text = CapabilityStatus.fromJson(_routingWaiting).describe('Routing');
      expect(text, startsWith(kMirrorFetchingSentence));
      expect(text, contains('Routing will be ready once it lands'));
      expect(text, contains('Waiting 3 min so far'));
      expect(text, isNot(contains('server')));
      expect(text, isNot(contains('internet')));
    });

    test('no upstream coverage reads as out of coverage, not a fault', () {
      const s = CapabilityStatus(ready: false, reason: 'failed:no_upstream_coverage');
      expect(s.describe('Routing'), contains('No map-data source covers this area'));
      expect(s.describe('Routing'), isNot(contains('no_upstream_coverage')));
    });
  });

  group('CapabilityWarmingNotice — the four readings', () {
    testWidgets('pending_upstream → the waiting state, with no retry', (tester) async {
      await tester.pumpWidget(_host(CapabilityWarmingNotice(
        capabilityLabel: 'Routing',
        status: CapabilityStatus.fromJson(_routingWaiting),
        onRetry: () {},
      )));
      expect(find.byKey(const ValueKey('capability-pending-upstream')), findsOneWidget);
      expect(find.textContaining(kMirrorFetchingSentence), findsOneWidget);
      expect(find.byIcon(Icons.cloud_download_outlined), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      expect(find.textContaining('unavailable'), findsNothing);
    });

    testWidgets('ready → content, when the status flips with no Author action',
        (tester) async {
      final status = ValueNotifier(CapabilityStatus.fromJson(_routingWaiting));
      await tester.pumpWidget(_host(ValueListenableBuilder<CapabilityStatus>(
        valueListenable: status,
        builder: (_, s, _) => s.ready
            ? const Text('route controls')
            : CapabilityWarmingNotice(capabilityLabel: 'Routing', status: s),
      )));
      expect(find.textContaining(kMirrorFetchingSentence), findsOneWidget);

      // The next `/health` poll — nothing tapped.
      status.value = CapabilityStatus.fromJson({'ready': true});
      await tester.pump();
      expect(find.textContaining(kMirrorFetchingSentence), findsNothing);
      expect(find.text('route controls'), findsOneWidget);
    });

    testWidgets('failed:* → the error card', (tester) async {
      await tester.pumpWidget(_host(CapabilityWarmingNotice(
        capabilityLabel: 'Routing',
        status: const CapabilityStatus(
            ready: false, reason: 'failed:fill_timeout (fill osm-cell-1d-36-80)'),
        onRetry: () {},
      )));
      expect(find.text('Routing is unavailable'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byKey(const ValueKey('capability-pending-upstream')), findsNothing);
    });

    testWidgets('no_upstream_coverage → the out-of-coverage notice', (tester) async {
      await tester.pumpWidget(_host(CapabilityWarmingNotice(
        capabilityLabel: 'Routing',
        status: const CapabilityStatus(ready: false, reason: 'failed:no_upstream_coverage'),
        onRetry: () {},
      )));
      expect(find.byKey(const ValueKey('capability-no-upstream-coverage')), findsOneWidget);
      expect(find.textContaining('No map-data source covers this area'), findsOneWidget);
      expect(find.text('Routing is unavailable'), findsNothing);
      expect(find.text('Try again'), findsNothing);
    });
  });

  group('the map\'s basemap notice', () {
    final viewport = LatLngBounds(const ll.LatLng(35.9, -80.0), const ll.LatLng(36.2, -79.6));

    test('a viewport over a filling cell is a wait; one beside it is not', () {
      expect(
          viewportTouchesFillingCells(viewport, [
            [-80.0, 36.0, -78.0, 38.0],
          ]),
          isTrue);
      expect(
          viewportTouchesFillingCells(viewport, [
            [-84.0, 34.0, -82.0, 36.0],
          ]),
          isFalse);
      expect(viewportTouchesFillingCells(viewport, const []), isFalse);
    });

    testWidgets('pendingUpstream shows the mirror wording, not "no tiles here"',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: const [
            Positioned(
                left: 0,
                bottom: 0,
                child: NoBasemapNotice(loading: false, pendingUpstream: true)),
          ]),
        ),
      ));
      expect(find.text(kMirrorFetchingSentence), findsOneWidget);
      expect(find.textContaining('No basemap tiles here'), findsNothing);
      expect(find.byIcon(Icons.cloud_download_outlined), findsOneWidget);
    });
  });
}
