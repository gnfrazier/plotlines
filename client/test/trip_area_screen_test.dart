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
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/screens/trip_area_screen.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

Future<void> _settleMap(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Widget _harness({List<Override> overrides = const [], required GoRouter router}) {
  return ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(AppDatabase.forTesting(NativeDatabase.memory())),
      ...overrides,
    ],
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
    await tester.pumpWidget(_harness(router: router));
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
    final router = _routerFor(
      (context, state) => const TripAreaScreen(isCreation: true, initialCenter: [-105.27, 40.02]),
      onReachedNewRoute: (extra) {
        reachedNew = true;
        reachedExtra = extra;
      },
    );
    await tester.pumpWidget(_harness(router: router));
    await _settleMap(tester);

    await tester.dragFrom(const Offset(200, 150), const Offset(120, 90));
    await _settleMap(tester);

    expect(find.text('NORTH'), findsOneWidget); // extent readout appeared

    final useExtent = tester.widget<ElevatedButton>(
      find.ancestor(of: find.text('Use this extent'), matching: find.byType(ElevatedButton)),
    );
    expect(useExtent.onPressed, isNotNull);

    await tester.tap(find.text('Use this extent'));
    await _settleMap(tester);

    expect(reachedNew, isTrue);
    // The trip-creation center flows through to New Route unchanged — the
    // bbox never substitutes for it.
    expect(reachedExtra, [-105.27, 40.02]);
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
      overrides: [tripBboxProvider.overrideWith((ref) => TripBboxNotifier()..set(existing))],
      router: router,
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await _settleMap(tester);

    expect(find.text('40.1000'), findsOneWidget); // NORTH reads back the existing bbox

    await tester.tap(find.text('Use this extent'));
    await _settleMap(tester);

    // Popped back to the shell, not pushed on to New Route a second time.
    expect(find.text('open'), findsOneWidget);
    expect(reachedNew, isFalse);
  });
}
