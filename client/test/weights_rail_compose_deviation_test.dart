// FR118 (Story A0a) — "See what my chosen places make": the compose-mode
// deviation panel (`WeightsRail`'s `_ComposeDeviationPanel`) as the Author
// meets it — realized distance reported against a stated band, framed as
// an editing decision with its five affordances, never as an error banner.
// Builds on the same Trip Shell harness `weights_rail_planning_mode_test.dart`
// already proved out.
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

const _spineCoordA = [-105.23, 40.03];
const _spineCoordB = [-105.22, 40.04];

Segment _overBandSegment() => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.27, 40.02],
      end: const [-105.2, 40.05],
      via: const [_spineCoordA, _spineCoordB],
      metrics: RouteMetrics(distanceM: 151000, climbM: 2410, movingTimeS: 31200, elapsedTimeS: 37500),
      elevation: Elevation(ascentM: 2410),
      bands: [Band(attribute: 'distance_m', min: 88000, max: 113000)],
      weights: WeightProfile(name: 'balanced', climbing: 3.0),
      solve: SolveProvenance(solvedAt: '2026-08-17T00:00:00Z'),
    );

Trip _fixtureTrip({Segment? segment, List<Day> extraDays = const []}) {
  final day = Day(id: 'day-1', index: 1, segments: [segment ?? _overBandSegment()]);
  return Trip(
    id: 'trip-1',
    title: 'Test Loop',
    createdAt: '2026-08-17T00:00:00Z',
    updatedAt: '2026-08-17T00:00:00Z',
    days: [day, ...extraDays],
    anchors: [
      Anchor(
        id: 'anchor-a',
        coord: _spineCoordA,
        title: 'Old Fort depot',
        roles: [Role(id: 'r1', kind: RoleKind.narrative)],
      ),
      Anchor(
        id: 'anchor-b',
        coord: _spineCoordB,
        title: 'Andrews Geyser',
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

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _settle(tester);
  await tester.tap(finder);
  await _settle(tester);
}

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

  Future<void> switchToCompose(WidgetTester tester) => _tap(tester, find.text('COMPOSE'));

  testWidgets('reports the realized day as an editing decision, quoting the AC\'s pattern',
      (tester) async {
    await pumpShell(tester);
    await switchToCompose(tester);

    expect(
      _inWeightsRail(find.text(
        'These 2 plot points make a 151.0 km day. Your band was 88.0–113.0 km.',
      )),
      findsOneWidget,
    );
    expect(_inWeightsRail(find.textContaining('moving')), findsOneWidget);
    expect(_inWeightsRail(find.textContaining('elapsed')), findsOneWidget);
    // Never routed through A6's conflict/error surface.
    expect(find.text('Diagnose'), findsNothing);
    expect(find.byTooltip('Conflict'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offers all five A0a affordances when the day is over its band', (tester) async {
    await pumpShell(tester);
    await switchToCompose(tester);

    expect(_inWeightsRail(find.text('Drop an anchor…')), findsOneWidget);
    expect(_inWeightsRail(find.text('Move to another day…')), findsNothing); // no other day yet
    expect(_inWeightsRail(find.text('Split the day')), findsOneWidget);
    expect(_inWeightsRail(find.text('Widen the band')), findsOneWidget);
    expect(_inWeightsRail(find.text('Accept')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('"move to another day" appears once a receiving day exists', (tester) async {
    final otherDaySegment = Segment(
      id: 'seg-2',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.1, 40.1],
      end: const [-105.05, 40.12],
    );
    final trip = _fixtureTrip(extraDays: [
      Day(id: 'day-2', index: 2, segments: [otherDaySegment]),
    ]);
    await pumpShell(tester, trip: trip);
    await switchToCompose(tester);

    expect(_inWeightsRail(find.text('Move to another day…')), findsOneWidget);

    await _tap(tester, find.text('Move to another day…'));
    expect(find.text('Move Old Fort depot to day 2'), findsOneWidget);
    expect(find.text('Move Andrews Geyser to day 2'), findsOneWidget);
  });

  testWidgets('"widen the band" widens the max to admit the realized distance', (tester) async {
    await pumpShell(tester);
    await switchToCompose(tester);

    await _tap(tester, find.text('Widen the band'));

    final trip = ProviderScope.containerOf(tester.element(find.byType(WeightsRail)))
        .read(currentTripProvider);
    final band = trip.days.single.segments.single.bands.single;
    expect(band.min, 88000);
    expect(band.max, 151000);
  });

  testWidgets('"accept" acknowledges the deviation and the button reflects it', (tester) async {
    await pumpShell(tester);
    await switchToCompose(tester);

    await _tap(tester, find.text('Accept'));

    expect(_inWeightsRail(find.text('Accepted')), findsWidgets);
    expect(_inWeightsRail(find.text('Accept')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('"drop an anchor" removes the chosen anchor from the spine', (tester) async {
    await pumpShell(tester);
    await switchToCompose(tester);

    await _tap(tester, find.text('Drop an anchor…'));
    await _tap(tester, find.text('Andrews Geyser').last);

    final trip = ProviderScope.containerOf(tester.element(find.byType(WeightsRail)))
        .read(currentTripProvider);
    expect(trip.days.single.segments.single.via, const [_spineCoordA]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('within-band compose days are reported without a warning tone and no widen action',
      (tester) async {
    final segment = _overBandSegment().copyWith(
      metrics: RouteMetrics(distanceM: 100000, climbM: 1200),
      bands: [Band(attribute: 'distance_m', min: 88000, max: 113000)],
    );
    await pumpShell(tester, trip: _fixtureTrip(segment: segment));
    await switchToCompose(tester);

    expect(
      _inWeightsRail(find.text(
        'These 2 plot points make a 100.0 km day. Your band was 88.0–113.0 km.',
      )),
      findsOneWidget,
    );
    expect(_inWeightsRail(find.text('Widen the band')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty spine reports nothing to show yet, not an error', (tester) async {
    final segment = Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.27, 40.02],
      end: const [-105.2, 40.05],
    );
    await pumpShell(tester, trip: _fixtureTrip(segment: segment));
    await switchToCompose(tester);

    expect(
      _inWeightsRail(find.text(
        'Add places to the spine and regenerate to see what they make of the day.',
      )),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
