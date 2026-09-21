// K10 / FR86, FR95, FR101 (issue #116) — the About pane shows elevation's
// CC BY and the basemap's ODbL credit together, a line per loaded plugin
// layer, the sidecar version, a build-failure warning when the service
// reports attribution incomplete, and a one-tap path to the privacy
// statement (K11). Attribution is derived from `GET /about`, never hardcoded;
// the static two credits are the offline fallback so the obligation is met
// even with no sidecar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/presentation/screens/privacy_screen.dart';
import 'package:plotlines_client/presentation/screens/settings_screen.dart';
import 'package:plotlines_client/presentation/screens/software_notices_screen.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

class _FakeRoutingClient extends RoutingClient {
  _FakeRoutingClient(this._about) : super('http://127.0.0.1:0');

  final Map<String, dynamic> Function() _about;

  @override
  Future<Map<String, dynamic>> about() async => _about();
}

/// #367/#454 — a sidecar manager whose `/health` snapshot is fixed rather
/// than polled, so `AboutPane`'s mirror/tiles-upstream advisories can be
/// driven directly.
class _FakeSidecarManager extends SidecarManager {
  _FakeSidecarManager([this._capabilities]);
  final Capabilities? _capabilities;

  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
  @override
  Capabilities? get capabilities => _capabilities;
}

Future<void> _pump(
  WidgetTester tester,
  RoutingClient client, {
  Capabilities? capabilities,
}) async {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        routingClientProvider.overrideWithValue(client),
        sidecarManagerProvider.overrideWith(
            (ref) => _FakeSidecarManager(capabilities)),
      ],
      child: MaterialApp(
        home: const Scaffold(body: AboutPane()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> _fullAbout({bool complete = true}) => {
      'app_version': '0.0.1',
      'sidecar_version': '0.0.1',
      'mode': 'sidecar',
      'attribution_complete': complete,
      'missing_attribution': complete ? <String>[] : ['revwar_battlefields'],
      'attributions': [
        {
          'layer': 'elevation',
          'licence': 'CC-BY-4.0',
          'attribution': 'Elevation: GEDTM30 © OpenTopography and contributors — CC BY 4.0',
          'builtin': true,
        },
        {
          'layer': 'basemap',
          'licence': 'ODbL-1.0',
          'attribution': '© OpenStreetMap contributors',
          'builtin': true,
        },
        {
          'layer': 'graph',
          'licence': 'ODbL-1.0',
          'attribution': 'Routing data: © OpenStreetMap contributors',
          'builtin': true,
        },
        {
          'layer': 'revwar_battlefields',
          'licence': 'CC-BY-4.0',
          'attribution': 'Revolutionary War GIS Project',
          'builtin': false,
        },
      ],
      'privacy': [
        {'id': 'reveal', 'title': 'Reveal is not a lock', 'body': 'Body.'},
      ],
      'software_notices': [
        {'name': 'pyinstaller', 'version': '6.22.3', 'licence': 'GPL-2.0-or-later', 'text': 'full text'},
      ],
      'software_notices_available': true,
    };

void main() {
  testWidgets('shows elevation CC BY and basemap ODbL together, plus plugin credit',
      (tester) async {
    await _pump(tester, _FakeRoutingClient(_fullAbout));

    expect(find.textContaining('CC BY 4.0'), findsOneWidget);
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    expect(find.text('Revolutionary War GIS Project'), findsOneWidget);
    expect(find.textContaining('CC-BY-4.0'), findsWidgets);
    expect(find.textContaining('ODbL-1.0'), findsWidgets);
    expect(find.textContaining('Sidecar version 0.0.1'), findsOneWidget);
  });

  testWidgets('shows the routing graph as its own credit, distinct from the basemap',
      (tester) async {
    // Issue #269: the graph is a separate ODbL obligation from the
    // basemap's, labelled as its own source rather than falling into the
    // generic "Layer — <name>" plugin bucket.
    await _pump(tester, _FakeRoutingClient(_fullAbout));

    expect(find.text('Routing graph'), findsOneWidget);
    expect(find.text('Routing data: © OpenStreetMap contributors'), findsOneWidget);
    expect(find.text('Layer — graph'), findsNothing);
  });

  testWidgets('surfaces a build-failure warning when attribution is incomplete',
      (tester) async {
    await _pump(tester, _FakeRoutingClient(() => _fullAbout(complete: false)));

    expect(find.textContaining('Attribution incomplete for: revwar_battlefields'),
        findsOneWidget);
    expect(find.textContaining('build failure'), findsOneWidget);
  });

  testWidgets('falls back to the two static credits when the sidecar is unreachable',
      (tester) async {
    final client = _FakeRoutingClient(() => throw Exception('sidecar down'));
    await _pump(tester, client);

    // The licence obligation is still met on the lightest surface.
    expect(find.textContaining('CC BY 4.0'), findsOneWidget);
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    expect(find.textContaining('Sidecar version: unavailable'), findsOneWidget);
  });

  testWidgets('the privacy statement is one tap from About', (tester) async {
    await _pump(tester, _FakeRoutingClient(_fullAbout));

    expect(find.text('Privacy & data'), findsOneWidget);
    // Issue #314 — the nav row is a bordered card on its pane, like the
    // credit cards above it, not a bare divider row on an unbroken canvas.
    expect(
      find.ancestor(
        of: find.text('Privacy & data'),
        matching: find.byType(PlotCard),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Privacy & data'));
    await tester.pumpAndSettle();

    expect(find.byType(PrivacyScreen), findsOneWidget);
    expect(find.text('What Plotlines knows and shares'), findsOneWidget);
  });

  testWidgets(
      'software notices are a separate section from data attribution, one tap from About',
      (tester) async {
    // Issue #267 — never folded into the DATA & ATTRIBUTION cards above.
    await _pump(tester, _FakeRoutingClient(_fullAbout));

    expect(find.text('SOFTWARE NOTICES'), findsOneWidget);
    expect(find.text('Sidecar & core licences'), findsOneWidget);
    expect(find.text('1 third-party packages'), findsOneWidget);
    expect(find.text('Plotlines app licences'), findsOneWidget);

    await tester.tap(find.text('Sidecar & core licences'));
    await tester.pumpAndSettle();

    expect(find.byType(SoftwareNoticesScreen), findsOneWidget);
    expect(find.textContaining('pyinstaller'), findsOneWidget);
  });

  testWidgets('shows an explanatory empty state when no bundle is available',
      (tester) async {
    final about = _fullAbout()
      ..['software_notices'] = <Map<String, dynamic>>[]
      ..['software_notices_available'] = false;
    await _pump(tester, _FakeRoutingClient(() => about));

    expect(find.text('Not available in this build (running from source)'),
        findsOneWidget);

    await tester.tap(find.text('Sidecar & core licences'));
    await tester.pumpAndSettle();

    expect(find.textContaining('only ships with a'), findsOneWidget);
  });

  group('mirror staleness advisory (issue #367)', () {
    Capabilities capsWithMirror(Map<String, dynamic> mirrorJson) =>
        Capabilities.fromJson({
          'tiles': {'ready': true},
          'layers': {'ready': true},
          'routing': {'regions': <String, dynamic>{}},
          'elevation': {'ready': false, 'reason': 'x'},
          'mirror': mirrorJson,
        });

    testWidgets('not configured shows no advisory — absence must not read as fresh',
        (tester) async {
      await _pump(tester, _FakeRoutingClient(_fullAbout),
          capabilities: capsWithMirror({'configured': false}));

      expect(find.textContaining('out of date'), findsNothing);
    });

    testWidgets('a fresh mirror shows no advisory', (tester) async {
      await _pump(tester, _FakeRoutingClient(_fullAbout),
          capabilities: capsWithMirror({
            'configured': true,
            'stale': false,
            'basemap': {'build_id': '20250101-wnc', 'age_days': 3.0, 'stale': false},
            'geofabrik': {'pinned_date': '2026-09-01', 'regions': {}, 'stale': false},
          }));

      expect(find.textContaining('out of date'), findsNothing);
    });

    testWidgets('a stale mirror surfaces an advisory naming the basemap age',
        (tester) async {
      await _pump(tester, _FakeRoutingClient(_fullAbout),
          capabilities: capsWithMirror({
            'configured': true,
            'stale': true,
            'basemap': {'build_id': '20250101-wnc', 'age_days': 52.0, 'stale': true},
            'geofabrik': {'pinned_date': '2026-07-01', 'regions': {}, 'stale': false},
          }));

      expect(find.textContaining('out of date'), findsOneWidget);
      expect(find.textContaining('52 days'), findsOneWidget);
      // Advisory, not an error: it must read differently from the
      // attribution-incomplete build-failure text above it.
      expect(find.textContaining('build failure'), findsNothing);
    });

    testWidgets('an unreachable mirror surfaces the error rather than staying silent',
        (tester) async {
      await _pump(tester, _FakeRoutingClient(_fullAbout),
          capabilities: capsWithMirror({
            'configured': true,
            'stale': true,
            'error': 'URLError: unreachable',
          }));

      expect(find.textContaining("Couldn't check whether map data is up to date"),
          findsOneWidget);
      expect(find.textContaining('URLError'), findsOneWidget);
    });
  });

  group('tile upstream refusal advisory (issue #454)', () {
    Capabilities capsWithTilesUpstream(Map<String, dynamic> upstreamJson) =>
        Capabilities.fromJson({
          'tiles': {'ready': true, 'upstream': upstreamJson},
          'layers': {'ready': true},
          'routing': {'regions': <String, dynamic>{}},
          'elevation': {'ready': false, 'reason': 'x'},
        });

    testWidgets('an ordinary mirror upstream shows no advisory', (tester) async {
      await _pump(tester, _FakeRoutingClient(_fullAbout),
          capabilities: capsWithTilesUpstream({
            'kind': 'mirror',
            'source': 'https://tiles.plotlines.app/basemap/protomaps/x/y.pmtiles',
            'refused': false,
            'reason': null,
          }));

      expect(find.textContaining('refused'), findsNothing);
    });

    testWidgets('a refused foreign host surfaces the reason (FR92/FR95)',
        (tester) async {
      await _pump(tester, _FakeRoutingClient(_fullAbout),
          capabilities: capsWithTilesUpstream({
            'kind': 'foreign',
            'source': 'https://tile.openstreetmap.org/x.pmtiles',
            'refused': true,
            'reason': "tile upstream 'tile.openstreetmap.org' is not the "
                'Plotlines mirror (FR92/FR95).',
          }));

      expect(find.textContaining('Basemap tile source was refused'), findsOneWidget);
      expect(find.textContaining('FR92/FR95'), findsOneWidget);
    });
  });
}
