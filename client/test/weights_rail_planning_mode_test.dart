// FR117/FR119 (Story A0) — the explore/compose planning-mode switch as the
// Author actually meets it: a visible toggle on the Route tab's weights
// rail, a distance control whose meaning changes with the mode, and a
// switch that loses no authored work in either direction. Builds on the
// same Trip Shell harness `trip_shell_screen_test.dart` already proved out
// (WeightsRail mounts and renders for a real fixture segment).
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/trip_shell_screen.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'package:plotlines_client/state/providers.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

const _spineCoord = [-105.23, 40.03];
const _spareCoord = [-105.30, 40.10];

Trip _fixtureTrip() {
  final segment = Segment(
    id: 'seg-1',
    mode: 'cycling',
    shape: 'point_to_point',
    start: const [-105.27, 40.02],
    end: const [-105.2, 40.05],
    via: const [_spineCoord],
    geometry: LineString(coordinates: const [
      [-105.27, 40.02],
      [-105.2, 40.05],
    ]),
    metrics: RouteMetrics(distanceM: 12000, climbM: 120),
    weights: WeightProfile(name: 'balanced', climbing: 3.0, poiDensity: 4.0),
    bands: [Band(attribute: 'distance_m', min: 7000, max: 9000)],
    solve: SolveProvenance(solvedAt: '2026-08-17T00:00:00Z'),
  );
  final day = Day(id: 'day-1', index: 1, segments: [segment]);
  return Trip(
    id: 'trip-1',
    title: 'Test Loop',
    createdAt: '2026-08-17T00:00:00Z',
    updatedAt: '2026-08-17T00:00:00Z',
    days: [day],
    anchors: [
      Anchor(
        id: 'anchor-in-spine',
        coord: _spineCoord,
        title: 'Overlook Anchor',
        roles: [Role(id: 'r1', kind: RoleKind.narrative)],
      ),
      Anchor(
        id: 'anchor-spare',
        coord: _spareCoord,
        title: 'Spare Point',
        roles: [Role(id: 'r2', kind: RoleKind.narrative)],
      ),
    ],
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The rail's bottom rail can outgrow the fixed-height budget the wireframe
/// gives it once the spine has entries, so its middle section scrolls —
/// this scrolls a given finder into view before tapping it, the way an
/// Author would themselves.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _settle(tester);
  await tester.tap(finder);
  await _settle(tester);
}

/// [find.text] alone is ambiguous for a distance readout — `MetricsRail`
/// (the Route tab's other rail) reports the same distance in several
/// places. Scope to WeightsRail's own subtree.
Finder _inWeightsRail(Finder matching) =>
    find.descendant(of: find.byType(WeightsRail), matching: matching);

void main() {
  Future<void> pumpShell(WidgetTester tester, {Trip? trip}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
          appDatabaseProvider.overrideWithValue(AppDatabase.forTesting(NativeDatabase.memory())),
          currentTripProvider
              .overrideWith((ref) => CurrentTripNotifier(ref)..open(trip ?? _fixtureTrip())),
          selectedSegmentProvider.overrideWith((ref) => ('day-1', 'seg-1')),
        ],
        child: const MaterialApp(home: TripShellScreen()),
      ),
    );
    await tester.pump();
  }

  testWidgets('the day opens in explore, with the mode always visible', (tester) async {
    await pumpShell(tester);

    expect(find.text('EXPLORE'), findsOneWidget);
    expect(find.text('COMPOSE'), findsOneWidget);
    // Explore's distance control is the editable constraint field.
    expect(find.text('Target distance (km)'), findsOneWidget);
    expect(find.text('DISTANCE — REPORTED OUTCOME'), findsNothing);
    // Bands are explore-only, and the fixture already carries one.
    expect(find.text('BANDS'), findsOneWidget);
    expect(find.text('Diagnose'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching to compose flips the distance control to a reported outcome '
      'and swaps bands for the spine', (tester) async {
    await pumpShell(tester);

    await _tap(tester, find.text('COMPOSE'));

    expect(find.text('DISTANCE — REPORTED OUTCOME'), findsOneWidget);
    expect(_inWeightsRail(find.text('12.0 km')), findsOneWidget); // the fixture's realized metrics.distanceM
    expect(find.text('Target distance (km)'), findsNothing);
    expect(find.text('BANDS'), findsNothing);
    expect(find.text('SPINE'), findsOneWidget);
    // The via coord already matches a promoted anchor, so the spine shows
    // its title rather than "Custom point".
    expect(find.text('Overlook Anchor'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the spine offers only anchors not already in it', (tester) async {
    await pumpShell(tester);
    await _tap(tester, find.text('COMPOSE'));

    // Open the "Add place" menu and confirm only the un-added anchor shows.
    await _tap(tester, find.text('Add place'));

    expect(find.text('Spare Point'), findsOneWidget);
    // The anchor already in the spine must not also show up in the menu.
    expect(find.text('Overlook Anchor'), findsNWidgets(1)); // only the spine row, not a duplicate menu entry
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching compose -> explore backfills the empty distance field from the '
      'realized outcome, without losing the spine (FR119)', (tester) async {
    await pumpShell(tester);

    await _tap(tester, find.text('COMPOSE'));
    await _tap(tester, find.text('EXPLORE'));

    expect(find.text('DISTANCE — REPORTED OUTCOME'), findsNothing);
    final field = tester.widget<TextField>(find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Target distance (km)',
    ));
    expect(field.controller?.text, '12.0');
    expect(tester.takeException(), isNull);

    // The spine (via) survives the round trip even though explore doesn't
    // display it as a "SPINE" section — flip back to compose to check.
    await _tap(tester, find.text('COMPOSE'));
    expect(find.text('Overlook Anchor'), findsOneWidget);
  });

  testWidgets('an authored explore target is never overwritten by the compose backfill',
      (tester) async {
    final trip = _fixtureTrip();
    final day = trip.days.single;
    final segment = day.segments.single.copyWith(targetDistance: TargetDistance(valueM: 5000));
    await pumpShell(tester, trip: trip.copyWith(days: [day.copyWith(segments: [segment])]));

    await _tap(tester, find.text('COMPOSE'));
    await _tap(tester, find.text('EXPLORE'));

    final field = tester.widget<TextField>(find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Target distance (km)',
    ));
    expect(field.controller?.text, '5.0'); // the Author's own value, not the realized 12.0
    expect(tester.takeException(), isNull);
  });
}
