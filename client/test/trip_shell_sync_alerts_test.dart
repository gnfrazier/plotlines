// Issue #210 / Story C11 (FR27) — the Trip Shell raises the worst-first
// sync-alert set as an interrupt when a trip with high-severity hazards is
// opened, and stays quiet for a trip that carries only `caution` markers
// (FR115: a hazard is never hidden, but only `high`/`mandatory_reroute`
// interrupt).
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

Trip _tripWithHazards(List<Hazard> segmentHazards) {
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
    metrics: RouteMetrics(distanceM: 8000),
    hazards: segmentHazards,
  );
  return Trip(
    id: 'trip-hazards',
    title: 'Hazard Loop',
    createdAt: '2026-08-31T00:00:00Z',
    updatedAt: '2026-08-31T00:00:00Z',
    days: [Day(id: 'day-1', index: 1, segments: [segment])],
  );
}

Future<void> _pumpShell(WidgetTester tester, Trip trip) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
        appDatabaseProvider.overrideWithValue(AppDatabase.forTesting(NativeDatabase.memory())),
        currentTripProvider.overrideWith((ref) => CurrentTripNotifier(ref)..open(trip)),
        selectedSegmentProvider.overrideWith((ref) => ('day-1', 'seg-1')),
      ],
      child: const MaterialApp(home: TripShellScreen()),
    ),
  );
  await tester.pump(); // build
  await tester.pump(); // post-frame callback -> showDialog
}

void main() {
  testWidgets('a high-severity hazard raises the sync-alert interrupt on open', (tester) async {
    await _pumpShell(tester, _tripWithHazards([
      Hazard(id: 'h-bridge', severity: 'mandatory_reroute', title: 'Bridge out at Elk Creek',
          safetyNote: 'Ford impassable above 2 m. Use the FS-19 detour.'),
      Hazard(id: 'h-grit', severity: 'caution', title: 'Loose gravel'),
    ]));

    expect(find.text('Hazards on this trip'), findsOneWidget);
    expect(find.text('Bridge out at Elk Creek'), findsOneWidget);
    expect(find.text('MANDATORY RE-ROUTE'), findsOneWidget);
    // the lone caution hazard is not raised as an alert, but is accounted for
    expect(find.textContaining('1 more lower-severity hazard'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.text('Hazards on this trip'), findsNothing);
  });

  testWidgets('a trip with only caution hazards does not interrupt', (tester) async {
    await _pumpShell(tester, _tripWithHazards([
      Hazard(id: 'h-grit', severity: 'caution', title: 'Loose gravel'),
    ]));

    expect(find.text('Hazards on this trip'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
