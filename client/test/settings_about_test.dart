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
import 'package:plotlines_client/presentation/screens/privacy_screen.dart';
import 'package:plotlines_client/presentation/screens/settings_screen.dart';
import 'package:plotlines_client/state/providers.dart';

class _FakeRoutingClient extends RoutingClient {
  _FakeRoutingClient(this._about) : super('http://127.0.0.1:0');

  final Map<String, dynamic> Function() _about;

  @override
  Future<Map<String, dynamic>> about() async => _about();
}

Future<void> _pump(WidgetTester tester, RoutingClient client) async {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [routingClientProvider.overrideWithValue(client)],
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
          'layer': 'revwar_battlefields',
          'licence': 'CC-BY-4.0',
          'attribution': 'Revolutionary War GIS Project',
          'builtin': false,
        },
      ],
      'privacy': [
        {'id': 'reveal', 'title': 'Reveal is not a lock', 'body': 'Body.'},
      ],
    };

void main() {
  testWidgets('shows elevation CC BY and basemap ODbL together, plus plugin credit',
      (tester) async {
    await _pump(tester, _FakeRoutingClient(_fullAbout));

    expect(find.textContaining('CC BY 4.0'), findsOneWidget);
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    expect(find.text('Revolutionary War GIS Project'), findsOneWidget);
    expect(find.textContaining('CC-BY-4.0'), findsWidgets);
    expect(find.textContaining('ODbL-1.0'), findsOneWidget);
    expect(find.textContaining('Sidecar version 0.0.1'), findsOneWidget);
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
    await tester.tap(find.text('Privacy & data'));
    await tester.pumpAndSettle();

    expect(find.byType(PrivacyScreen), findsOneWidget);
    expect(find.text('What Plotlines knows and shares'), findsOneWidget);
  });
}
