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
}
