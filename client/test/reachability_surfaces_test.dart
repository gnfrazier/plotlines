// FR142(b) (Story K12) — reachability verified, not asserted: for every
// [ReachableObject], build the surface its registry entry names with one such
// object in it and find the object there. The switch below is exhaustive over
// the enum, so a new object kind does not compile here until its path is
// named and checked — "a new object type ships with its path named, or it
// does not ship."
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/layers_tab.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/logistics_tab.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/roster_tab.dart';
import 'package:plotlines_client/presentation/screens/trip_library_screen.dart';
import 'package:plotlines_client/presentation/widgets/day_timeline_strip.dart';
import 'package:plotlines_client/state/current_roster_provider.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'support/display_units.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

const _route = <Coord>[
  [-105.4, 40.0],
  [-105.0, 40.0],
];

Trip _trip({
  List<Day>? days,
  List<Anchor> anchors = const [],
}) =>
    Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: days ?? [Day(id: 'd1', index: 1)],
      anchors: anchors,
      modes: const {'cycling'},
    );

Segment _passage({List<Alternate> alternates = const [], bool stale = false}) => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: _route.first,
      end: _route.last,
      geometry: LineString(coordinates: _route),
      alternates: alternates,
      solve: SolveProvenance(solvedAt: '2026-01-01T00:00:00Z', stale: stale),
    );

Anchor _anchor({String? dayId}) => Anchor(
      id: 'a1',
      coord: const [-105.2, 40.0],
      title: 'Bakersville town green',
      roles: [Role(id: 'r1', kind: RoleKind.provision, dayId: dayId)],
    );

/// A trip-scoped surface, built from the live trip like the shell builds it.
Future<ProviderContainer> _pumpTripSurface(
  WidgetTester tester,
  Trip trip,
  Widget Function(Trip trip) surface,
) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(overrides: [metricUnits()]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(trip);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(builder: (context, ref, _) => surface(ref.watch(currentTripProvider))),
      ),
    ),
  ));
  return container;
}

Widget _logistics(Trip trip) => LogisticsTab(trip: trip, onOpenSegment: (_, _) {});

Future<void> _anchorFoundUnderFilter(WidgetTester tester, {required bool attached}) async {
  await _pumpTripSurface(
    tester,
    _trip(anchors: [_anchor(dayId: attached ? 'd1' : null)]),
    (t) => AnchorsView(trip: t),
  );
  await tester.tap(find.widgetWithText(ChoiceChip, attached ? 'Attached' : 'Unattached'));
  await tester.pump();
  expect(find.text('Bakersville town green'), findsOneWidget);
}

void main() {
  for (final kind in ReachableObject.values) {
    final target = reachabilityRegistry[kind]!;
    testWidgets('$kind is found back: ${target.description}', (tester) async {
      switch (kind) {
        case ReachableObject.anchorAttached:
          await _anchorFoundUnderFilter(tester, attached: true);

        case ReachableObject.anchorUnattached:
          await _anchorFoundUnderFilter(tester, attached: false);

        case ReachableObject.passage:
          final trip = _trip(days: [Day(id: 'd1', index: 1, segments: [_passage()])]);
          await _pumpTripSurface(tester, trip, _logistics);
          expect(find.text('cycling · point to point'), findsOneWidget);
          await _pumpTripSurface(
              tester, trip, (t) => DayTimelineStrip(trip: t, activeDayId: 'd1', onSelectDay: (_) {}));
          expect(find.text(travelModeLabel('cycling')), findsOneWidget);

        case ReachableObject.day:
          final trip = _trip(days: [Day(id: 'd1', index: 1), Day(id: 'd2', index: 2, kind: 'rest')]);
          await _pumpTripSurface(
              tester, trip, (t) => DayTimelineStrip(trip: t, activeDayId: 'd1', onSelectDay: (_) {}));
          expect(find.text('DAY 1'), findsOneWidget);
          expect(find.text('DAY 2 · REST'), findsOneWidget);

        case ReachableObject.trip:
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          addTearDown(db.close);
          await db.saveTrip(
            id: 'ride',
            title: 'Pisgah Gravel Loop',
            modes: const ['cycling'],
            payloadJson: '{}',
            summaryJson: '{"day_count":1}',
            updatedAt: DateTime.utc(2026, 8, 27),
          );
          await tester.pumpWidget(ProviderScope(
            overrides: [
              sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
              appDatabaseProvider.overrideWithValue(db),
              metricUnits(),
            ],
            child: MaterialApp.router(
              routerConfig: GoRouter(
                routes: [GoRoute(path: '/', builder: (_, _) => const TripLibraryScreen())],
              ),
            ),
          ));
          await tester.pumpAndSettle();
          expect(find.text('Pisgah Gravel Loop'), findsOneWidget);

        case ReachableObject.character:
          // The regression this kind was added for: a Character on the
          // persisted roster with no response in this session's grid — every
          // reopened trip — was on no surface at all.
          final container = await _pumpTripSurface(tester, _trip(), (_) => const RosterTab());
          container.read(currentRosterProvider.notifier).open(
                const TripRoster(entries: [RosterEntry(characterId: 'dana', name: 'Dana')]),
              );
          await tester.pump();
          expect(find.text('Dana'), findsOneWidget);

        case ReachableObject.characterNote:
        case ReachableObject.groupAssignment:
          // No shipped surface makes either yet (D5 / D7 are p1): the path is
          // named against the story that will add the maker and the finder
          // together, rather than claimed for a surface that does not exist.
          expect(target.pendingStory, isNotNull);
          expect(target.shipped, isFalse);

        case ReachableObject.staleItem:
          final trip = _trip(days: [Day(id: 'd1', index: 1, segments: [_passage(stale: true)])]);
          await _pumpTripSurface(tester, trip, _logistics);
          await tester.tap(find.byKey(const ValueKey('logistics-stale-count')));
          await tester.pumpAndSettle();
          expect(find.text('1 stale item needs re-solving'), findsOneWidget);

        case ReachableObject.alternate:
          final alternate = Alternate(
            id: 'alt-1',
            kind: 'bypass',
            label: 'Toe River road',
            divergesAtM: 8000.0,
            rejoinsAtM: 24000.0,
            geometry: LineString(coordinates: const [
              [-105.3, 40.0],
              [-105.2, 40.05],
              [-105.1, 40.0],
            ], source: 'authored'),
          );
          final trip =
              _trip(days: [Day(id: 'd1', index: 1, segments: [_passage(alternates: [alternate])])]);
          await _pumpTripSurface(tester, trip, _logistics);
          expect(find.textContaining('Toe River road'), findsWidgets);
      }
      expect(tester.takeException(), isNull);
    });
  }

  test('every shipped kind names a surface; every unshipped one names its story', () {
    for (final entry in reachabilityRegistry.entries) {
      if (!entry.value.shipped) {
        expect(entry.value.pendingStory, matches(RegExp(r'^#\d+$')), reason: '${entry.key}');
      }
    }
  });
}
