// Real coverage for the Trip Shell (`trip_shell_screen.dart`) introduced by
// the 2026-08-17 wireframe reconciliation — the previous `widget_test.dart`
// smoke test never routes past the trip library, so nothing had ever pumped
// a frame through the Route/Logistics/Content/Export tabs, the weights
// rail, the day timeline strip, or the node editor drawer before this file.
// Catches real Riverpod/widget-tree mistakes `flutter analyze` can't see —
// null Provider reads, missing overrides, exceptions during build — that a
// type-correct-but-wrong widget tree would otherwise only surface by
// actually running the app.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/map/tap_to_pick_map.dart';
import 'package:plotlines_client/presentation/screens/trip_shell_screen.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'package:plotlines_client/state/providers.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

Trip _fixtureTrip() {
  final segment = Segment(
    id: 'seg-1',
    mode: 'cycling',
    shape: 'point_to_point',
    start: const [-105.27, 40.02],
    end: const [-105.2, 40.05],
    geometry: LineString(coordinates: const [
      [-105.27, 40.02],
      [-105.2, 40.05],
    ]),
    metrics: RouteMetrics(distanceM: 8000, climbM: 120),
    weights: WeightProfile(name: 'balanced', climbing: 3.0, traffic: 1.0),
    bands: [Band(attribute: 'distance_m', min: 7000, max: 9000)],
    nodes: [
      Node(id: 'node-1', kind: NodeKind.poi, coord: const [-105.23, 40.03], title: 'Overlook'),
    ],
  );
  final day = Day(id: 'day-1', index: 1, segments: [segment]);
  return Trip(
    id: 'trip-1',
    title: 'Test Loop',
    createdAt: '2026-08-17T00:00:00Z',
    updatedAt: '2026-08-17T00:00:00Z',
    days: [day],
  );
}

/// The Trip Shell's tab switch is driven by a `TabController` animation —
/// one large `pump(duration)` doesn't reliably carry it to completion the
/// way several smaller pumps do (a `flutter_map`/`vector_map_tiles` ticker
/// elsewhere in the tree appears to interact with a single big time-jump),
/// so every tab switch in this file goes through several short pumps
/// instead of one `pumpAndSettle()` (which would hang on that same ticker).
Future<void> _switchTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('Trip Shell renders and switches between all four tabs', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
          appDatabaseProvider
              .overrideWithValue(AppDatabase.forTesting(NativeDatabase.memory())),
          currentTripProvider.overrideWith((ref) => CurrentTripNotifier(ref)..open(_fixtureTrip())),
          selectedSegmentProvider.overrideWith((ref) => ('day-1', 'seg-1')),
        ],
        child: const MaterialApp(home: TripShellScreen()),
      ),
    );
    await tester.pump();

    // Route tab (default): weights rail + day timeline both mounted.
    expect(find.text('ROUTE WEIGHTS'), findsOneWidget);
    expect(find.text('Peaks — climbing'), findsOneWidget); // FR2/A1's "peaks" terminology
    expect(find.text('DAY 1'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _switchTab(tester, 'LOGISTICS');
    expect(find.text('Day 1'), findsOneWidget);
    expect(find.text('Add segment'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Regression: "Add rest day" used to call setDayKind with a freshly
    // generated id, which only looks up *existing* days and throws when
    // nothing matches — this must add a day, not crash.
    await tester.tap(find.byTooltip('Add rest day'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // The new day's card is appended below the day list — scroll it into
    // view (the Logistics tab's own ListView is the scrollable).
    await tester.scrollUntilVisible(
      find.text('Day 2'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Day 2'), findsOneWidget);

    await _switchTab(tester, 'CONTENT');
    expect(find.text('Overlook'), findsOneWidget); // the fixture node, as a selectable chip
    expect(tester.takeException(), isNull);

    await _switchTab(tester, 'ROSTER');
    expect(find.text('PROFILE & PERMISSIONS REQUEST'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _switchTab(tester, 'EXPORT');
    expect(find.text('FORMAT'), findsOneWidget);
    expect(find.text('CONTENTS'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Back to Route — the rail should still reflect the selected segment.
    await _switchTab(tester, 'ROUTE');
    expect(find.text('ROUTE WEIGHTS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // Issue #323 — selecting a day used to move only the day strip / Layers
  // tab (`_activeDayId`); the map reads `selectedSegmentProvider`, which
  // nothing but a segment tap ever wrote, so another day's line stayed
  // drawn. Both assertions below fail against the pre-#323 code.
  testWidgets('selecting a day selects that day\'s first segment and the map follows',
      (tester) async {
    final day1 = Day(id: 'day-1', index: 1, segments: [
      Segment(
        id: 'seg-1',
        mode: 'cycling',
        shape: 'point_to_point',
        start: const [-105.27, 40.02],
        end: const [-105.20, 40.05],
        geometry: LineString(coordinates: const [
          [-105.27, 40.02],
          [-105.20, 40.05],
        ]),
        metrics: RouteMetrics(distanceM: 8000),
      ),
    ]);
    final day2 = Day(id: 'day-2', index: 2, segments: [
      Segment(
        id: 'seg-2',
        mode: 'cycling',
        shape: 'point_to_point',
        start: const [-105.10, 40.10],
        end: const [-105.00, 40.20],
        geometry: LineString(coordinates: const [
          [-105.10, 40.10],
          [-105.00, 40.20],
        ]),
        metrics: RouteMetrics(distanceM: 15000),
      ),
    ]);
    final day3 = Day(id: 'day-3', index: 3, kind: 'rest');
    final trip = Trip(
      id: 'trip-1',
      title: 'Multi-day',
      createdAt: '2026-09-08T00:00:00Z',
      updatedAt: '2026-09-08T00:00:00Z',
      days: [day1, day2, day3],
    );

    // A desktop-width surface — the Route tab is a three-column Row (weights
    // rail ~300px + map + metrics rail 308px), and the day chip strip is a
    // lazy horizontal ListView, so at the 800px default the third day chip
    // is never built.
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final container = ProviderContainer(overrides: [
      sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
      appDatabaseProvider.overrideWithValue(AppDatabase.forTesting(NativeDatabase.memory())),
      currentTripProvider.overrideWith((ref) => CurrentTripNotifier(ref)..open(trip)),
      // Start on Day 2's segment — the "another day is drawn" starting state.
      selectedSegmentProvider.overrideWith((ref) => ('day-2', 'seg-2')),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: TripShellScreen()),
      ),
    );
    await tester.pump();

    List<List<double>> mapPolyline() =>
        tester.widget<TapToPickMap>(find.byType(TapToPickMap)).polyline;

    // Precondition: Day 2's line is what's on the map.
    expect(mapPolyline(), day2.segments.single.geometry!.coordinates);

    // Select Day 1.
    await tester.tap(find.text('DAY 1'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(container.read(selectedSegmentProvider), ('day-1', 'seg-1'));
    expect(mapPolyline(), day1.segments.single.geometry!.coordinates);
    expect(tester.takeException(), isNull);

    // Select the rest day — no segment to select, so the selection clears
    // rather than leaving Day 1's line standing.
    await tester.tap(find.text('DAY 3 · REST'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(container.read(selectedSegmentProvider), isNull);
    expect(mapPolyline(), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
