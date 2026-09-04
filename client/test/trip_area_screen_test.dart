// N1 (PRD FR120) — the trip-extent screen: "Use this extent" stays
// disabled until something is drawn, drawing during trip creation proceeds
// to New Route's setup form with the same center the location prompt
// resolved to, and a revision (already-drawn bbox) reads back correctly
// and returns to wherever it was opened from instead of pushing New Route
// again.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/map/map_attribution.dart';
import 'package:plotlines_client/presentation/screens/trip_area_screen.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

/// This screen watches `tripRegionKeyProvider` to start the routing region
/// warm-up as the bbox is accepted. These tests are about the "Use this
/// extent" button, not the settle window (issue #246), so the region notifier
/// runs with a zero window against a stub client — otherwise every test that
/// draws a bbox leaks the real 10 s settle `Timer` into `FakeAsync`.
class _StubRoutingClient extends RoutingClient {
  _StubRoutingClient() : super('http://stub');
  @override
  Future<String> ensureRegion(List<double> bboxWsen,
          {String networkType = 'bike', bool retry = false}) async =>
      'region-stub';
}

Future<void> _settleMap(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

ProviderContainer _containerFor({List<Override> overrides = const []}) => ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(AppDatabase.forTesting(NativeDatabase.memory())),
        routingClientProvider.overrideWithValue(_StubRoutingClient()),
        tripRegionKeyProvider.overrideWith(
            (ref) => TripRegionKeyNotifier(ref, settleWindow: Duration.zero)),
        ...overrides,
      ],
    );

Widget _harness(ProviderContainer container, {required GoRouter router}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );
}

GoRouter _routerFor(
  Widget Function(BuildContext, GoRouterState) tripAreaBuilder, {
  required void Function(List<double>? extra) onReachedNewRoute,
}) {
  return GoRouter(
    initialLocation: '/trip-area',
    routes: [
      GoRoute(path: '/trip-area', builder: tripAreaBuilder),
      GoRoute(
        path: '/new',
        builder: (_, state) {
          onReachedNewRoute(state.extra as List<double>?);
          return const SizedBox.shrink();
        },
      ),
    ],
  );
}

void main() {
  testWidgets('Use this extent stays disabled until something is drawn', (tester) async {
    List<double>? reachedExtra;
    var reachedNew = false;
    final router = _routerFor(
      (context, state) => const TripAreaScreen(isCreation: true, initialCenter: [-105.27, 40.02]),
      onReachedNewRoute: (extra) {
        reachedNew = true;
        reachedExtra = extra;
      },
    );
    await tester.pumpWidget(_harness(_containerFor(), router: router));
    await _settleMap(tester);

    final useExtent = tester.widget<ElevatedButton>(
      find.ancestor(of: find.text('Use this extent'), matching: find.byType(ElevatedButton)),
    );
    expect(useExtent.onPressed, isNull);
    expect(reachedNew, isFalse);
    expect(reachedExtra, isNull);
  });

  testWidgets('drawing during trip creation enables the button and proceeds to New Route',
      (tester) async {
    List<double>? reachedExtra;
    var reachedNew = false;
    final container = _containerFor();
    final router = _routerFor(
      (context, state) => const TripAreaScreen(isCreation: true, initialCenter: [-105.27, 40.02]),
      onReachedNewRoute: (extra) {
        reachedNew = true;
        reachedExtra = extra;
      },
    );
    await tester.pumpWidget(_harness(container, router: router));
    await _settleMap(tester);

    await tester.dragFrom(const Offset(200, 150), const Offset(120, 90));
    await _settleMap(tester);

    // Issue #230 C1 — the readout leads with the area (the number a human
    // decides on); the raw decimal degrees moved behind an "Exact bounds"
    // disclosure rather than sitting above it at the same size and weight.
    expect(find.text('AREA'), findsOneWidget); // extent readout appeared
    expect(find.text('NORTH'), findsNothing); // collapsed until asked for
    await tester.ensureVisible(find.text('Exact bounds'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Exact bounds'));
    await tester.pumpAndSettle();
    expect(find.text('NORTH'), findsOneWidget);

    final useExtent = tester.widget<ElevatedButton>(
      find.ancestor(of: find.text('Use this extent'), matching: find.byType(ElevatedButton)),
    );
    expect(useExtent.onPressed, isNotNull);

    // Issue #154's second leak: `_confirm()` used to forward the
    // trip-creation center (`initialCenter`, [-105.27, 40.02] here)
    // unchanged rather than what the Author actually drew — picking "Use
    // Buncombe County, NC" (a null `initialCenter`) fell through to a
    // hardcoded Boulder default downstream. It must now forward the drawn
    // bbox's own center.
    final drawnBbox = container.read(tripBboxProvider);
    expect(drawnBbox, isNotNull);

    await tester.tap(find.text('Use this extent'));
    await _settleMap(tester);

    expect(reachedNew, isTrue);
    expect(reachedExtra, drawnBbox!.center);
    expect(reachedExtra, isNot([-105.27, 40.02]));
  });

  testWidgets('revising an already-drawn extent shows its readout and pops on confirm',
      (tester) async {
    const existing = TripBbox(minLat: 39.9, minLon: -105.4, maxLat: 40.1, maxLon: -105.1);
    var reachedNew = false;
    final router = GoRouter(
      initialLocation: '/shell',
      routes: [
        GoRoute(
          path: '/shell',
          builder: (context, state) =>
              ElevatedButton(onPressed: () => context.push('/trip-area'), child: const Text('open')),
        ),
        GoRoute(path: '/trip-area', builder: (context, state) => const TripAreaScreen(isCreation: false)),
        GoRoute(path: '/new', builder: (_, _) {
          reachedNew = true;
          return const SizedBox.shrink();
        }),
      ],
    );
    await tester.pumpWidget(_harness(
      _containerFor(
        overrides: [tripBboxProvider.overrideWith((ref) => TripBboxNotifier()..set(existing))],
      ),
      router: router,
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await _settleMap(tester);

    // Issue #230 C1 — the coordinates live under the "Exact bounds"
    // disclosure now; the area is what leads.
    expect(find.text('AREA'), findsOneWidget);
    await tester.ensureVisible(find.text('Exact bounds'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Exact bounds'));
    await tester.pumpAndSettle();
    expect(find.text('40.1000'), findsOneWidget); // NORTH reads back the existing bbox

    await tester.tap(find.text('Use this extent'));
    await _settleMap(tester);

    // Popped back to the shell, not pushed on to New Route a second time.
    expect(find.text('open'), findsOneWidget);
    expect(reachedNew, isFalse);
  });

  testWidgets('the basemap credit is on the map, not only in Preferences',
      (tester) async {
    // K10 / FR95 (issue #230 C1) — ODbL wants the notice with the produced
    // work. It lived in Preferences → DATA & ATTRIBUTION, so a screenshot of
    // the map carried no credit at all.
    final router = _routerFor(
      (context, state) => const TripAreaScreen(isCreation: true),
      onReachedNewRoute: (_) {},
    );
    await tester.pumpWidget(_harness(_containerFor(), router: router));
    await _settleMap(tester);

    expect(find.byType(MapAttribution), findsOneWidget);
    expect(find.text(MapAttribution.line), findsOneWidget);
    expect(MapAttribution.line, contains('OpenStreetMap'));
    expect(MapAttribution.line, contains('ODbL'));
  });

  testWidgets('a disabled "Use this extent" says why it will not act', (tester) async {
    // Flow 8's pattern is "disabled and says so"; this was light tan on tan
    // with nothing stating the reason (issue #230 C1).
    final container = _containerFor();
    final router = _routerFor(
      (context, state) => const TripAreaScreen(isCreation: true),
      onReachedNewRoute: (_) {},
    );
    await tester.pumpWidget(_harness(container, router: router));
    await _settleMap(tester);

    expect(find.textContaining('Drag a rectangle on the map'), findsOneWidget);

    await tester.dragFrom(const Offset(200, 150), const Offset(120, 90));
    await _settleMap(tester);

    // Once there is something to use, the reason goes away.
    expect(find.textContaining('Drag a rectangle on the map'), findsNothing);
  });

  testWidgets('trip creation says which step of it this is', (tester) async {
    // Issue #230 B1 — the mockups carry `NEW TRIP · STEP n OF m`; the
    // shipped screen gave no sense of position in the flow. A later revision
    // of an existing extent is not part of a numbered flow and shows none.
    final creation = _routerFor(
      (context, state) => const TripAreaScreen(isCreation: true),
      onReachedNewRoute: (_) {},
    );
    await tester.pumpWidget(_harness(_containerFor(), router: creation));
    await _settleMap(tester);
    expect(find.textContaining('STEP 2 OF 3'), findsOneWidget);

    final revision = _routerFor(
      (context, state) => const TripAreaScreen(isCreation: false),
      onReachedNewRoute: (_) {},
    );
    await tester.pumpWidget(_harness(_containerFor(), router: revision));
    await _settleMap(tester);
    expect(find.textContaining('STEP'), findsNothing);
  });
}
