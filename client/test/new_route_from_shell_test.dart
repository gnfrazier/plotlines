// Issue #655 — New Route is step 4 of trip creation, but the trip shell opens
// it too: *+ New route day*, *Add a route day*, *Add a passage*, *Add
// segment*. It behaved as step 4 every time:
//
// - F4: Blank canvas called `addBlankDay()` whatever day the Author had
//   picked, appending Day N+1, and the picked day was never cleared;
// - F6: the no-routable-data banner's *Choose area* popped one screen
//   (pinned in `new_route_panel_test.dart`, beside the #574 banner test);
// - F7: the "NEW TRIP · STEP 4 OF 4" eyebrow and the trip name, dates and
//   party block showed when adding a passage to an existing trip.
//
// The shell now opens `/add-route` (`NewRouteScreen(isCreation: false)`).
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/new_route_screen.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'package:plotlines_client/state/providers.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Trip _trip({Set<String> modes = const {'cycling'}}) => Trip(
      id: 't',
      title: 'Greensboro',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      modes: modes,
      days: [
        Day(id: 'd1', index: 1, segments: [
          Segment(id: 's1', mode: 'cycling', shape: 'loop', start: const [-79.5, 36.1]),
        ]),
        Day(id: 'd2', index: 2),
      ],
    );

Future<ProviderContainer> _open(WidgetTester tester, String location,
    {String? targetDayId, Set<String> modes = const {'cycling'}}) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(overrides: [
    appDatabaseProvider.overrideWithValue(db),
    sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
  ]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(_trip(modes: modes));
  container.read(plannerTargetDayIdProvider.notifier).state = targetDayId;
  final router = GoRouter(
    initialLocation: '/plan',
    routes: [
      GoRoute(path: '/plan', builder: (_, _) => const Text('SHELL')),
      GoRoute(path: '/new', builder: (_, _) => const NewRouteScreen()),
      GoRoute(path: '/add-route', builder: (_, _) => const NewRouteScreen(isCreation: false)),
      GoRoute(path: '/trip-area', builder: (_, _) => const Text('TRIP AREA')),
    ],
  );
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  ));
  router.push(location);
  await _settle(tester);
  return container;
}

void main() {
  testWidgets('F7 — from the shell there is no creation eyebrow and no trip-level fields',
      (tester) async {
    await _open(tester, '/add-route', targetDayId: 'd2');

    expect(find.text('NEW TRIP · STEP 4 OF 4'), findsNothing);
    expect(find.text('TRIP NAME'), findsNothing);
    expect(find.text('DATES'), findsNothing);
    expect(find.text('PARTY SIZE'), findsNothing);
    expect(find.text('Add a passage to Day 2'), findsOneWidget);
    expect(find.textContaining('chosen on the previous step'), findsNothing);
  });

  testWidgets('creation still shows step 4 and the trip-level fields', (tester) async {
    await _open(tester, '/new');

    expect(find.text('NEW TRIP · STEP 4 OF 4'), findsOneWidget);
    expect(find.text('TRIP NAME'), findsOneWidget);
    expect(find.text('DATES'), findsOneWidget);
    expect(find.text('PARTY SIZE'), findsOneWidget);
  });

  testWidgets('F4 — Blank canvas on a picked day starts a passage there, not a new day',
      (tester) async {
    final container = await _open(tester, '/add-route', targetDayId: 'd2');
    // The screen took the day as it opened; nothing is left for the next one.
    expect(container.read(plannerTargetDayIdProvider), isNull);

    await tester.tap(find.text('Blank canvas'));
    await _settle(tester);
    await tester.ensureVisible(find.widgetWithText(PlotButton, 'Start the passage'));
    await tester.tap(find.widgetWithText(PlotButton, 'Start the passage'));
    await _settle(tester);

    final trip = container.read(currentTripProvider);
    expect(trip.days, hasLength(2));
    final passage = trip.days[1].segments.single;
    expect(passage.mode, 'cycling');
    expect(passage.start, isNull);
    expect(container.read(selectedSegmentProvider), ('d2', passage.id));
    expect(find.text('SHELL'), findsOneWidget);
  });

  testWidgets('F4 — with several trip modes, the passage\'s mode is picked first', (tester) async {
    final container =
        await _open(tester, '/add-route', targetDayId: 'd2', modes: const {'cycling', 'hiking'});

    await tester.tap(find.text('Blank canvas'));
    await _settle(tester);
    await tester.ensureVisible(find.widgetWithText(PlotButton, 'Start the passage'));
    expect(tester.widget<PlotButton>(find.widgetWithText(PlotButton, 'Start the passage')).onPressed,
        isNull);

    await tester.tap(find.descendant(
        of: find.byType(SegmentedButton<String>), matching: find.text('Hike')));
    await _settle(tester);
    await tester.tap(find.widgetWithText(PlotButton, 'Start the passage'));
    await _settle(tester);

    expect(container.read(currentTripProvider).days[1].segments.single.mode, 'hiking');
  });

  testWidgets('Blank canvas with no day picked still adds a day', (tester) async {
    final container = await _open(tester, '/add-route');

    expect(find.text('New route day'), findsOneWidget);
    await tester.tap(find.text('Blank canvas'));
    await _settle(tester);
    await tester.ensureVisible(find.widgetWithText(PlotButton, 'Create route'));
    await tester.tap(find.widgetWithText(PlotButton, 'Create route'));
    await _settle(tester);

    expect(container.read(currentTripProvider).days, hasLength(3));
  });

  testWidgets('F4 — leaving without a route clears the picked day too', (tester) async {
    final container = await _open(tester, '/add-route', targetDayId: 'd2');
    await tester.pageBack();
    await _settle(tester);

    expect(container.read(plannerTargetDayIdProvider), isNull);
  });
}
